# The budget (FR-14, threat model SR-02, ADR-0003, ADR-0012): the ledger that
# charges every model call to the calendar month in São Paulo, and the mode
# the turn reads before any model call.
#
# - The ledger: each attempt of a model call is a usage record at the price
#   table's prices (Prices), and its cost is added to the month's spend in
#   the same transaction, under the month row's lock, so concurrent turns add
#   up. The spend lives on the month's row, which outlives the seven-day purge
#   of the usage records (FR-15).
# - The mode: a forced mode wins until it is released (the kill switch,
#   console from M2); otherwise paused from the cap on, normal below it.
#   Economy serves only on the full eval run's word (ADR-0003), the committed
#   evals/economy_allowed.yml, read once at boot (config/initializers/budget.rb);
#   without it a forced economy pauses. Economy at 70 %, the daily slice and
#   the operator's notification arrive at M3 (design §9.2).
# - The record: the read that finds the automatic mode changed writes it into
#   the month's row and one log line, whatever changed it (a charge past the
#   cap, a cap a deploy lowered or raised, the next month), saying which
#   forced mode serves when one wins (review finding S3 of pull request #29).
#   That line is where M3's operator notification will hook.
#
# The gate reads the mode once, when a turn starts: turns already running when
# the cap is reached finish, so the month may end a few turns past its cap
# (design §10, PR-16's note).
module Budget
  ECONOMY_ALLOWED = Rails.root.join("evals/economy_allowed.yml")

  module_function

  # The month's cap in US dollars: BUDGET_CAP_USD in each destination
  # (config/environments/production.rb), ADR-0003's default elsewhere
  # (config/application.rb).
  def cap = Rails.configuration.x.budget_cap_usd

  # The mode that serves, and whether a mode the operator forced made it: a
  # forced pause, or a forced economy the eval run has not allowed, answers
  # with a text of its own, the cap's pause with the month's (FR-14; the
  # owner, 2026-11-15).
  Status = Data.define(:mode, :forced)

  def status(at = Time.current)
    state = month(at)
    automatic = automatic(state.spent_usd)
    record(state, automatic) unless state.automatic_mode == automatic
    Status.new(mode: serving(state.forced_mode, automatic), forced: !state.forced_mode.nil?)
  end

  def mode(at = Time.current) = status(at).mode

  # The mode that serves: a forced one wins, and economy only on the eval
  # run's word.
  def serving(forced, automatic)
    mode = forced || automatic
    mode == "economy" && !economy_allowed? ? "paused" : mode
  end

  def automatic(spent) = spent >= cap ? "paused" : "normal"

  # Charges a turn's model calls, one usage record per attempt
  # (AgentRunner::Usage), and answers what they cost.
  def charge!(turn, usages, at: Time.current)
    return 0 if usages.empty?

    costs = usages.map { |usage| [ usage, Prices.cost_usd(usage).round(8) ] }
    total = costs.sum(&:last)
    state = month(at)
    state.with_lock do
      costs.each { |usage, cost| write_usage(turn, usage, cost) }
      state.update!(spent_usd: state.spent_usd + total)
    end
    total
  end

  # ADR-0003's gate as the boot read it: nothing but a true lets economy serve.
  def economy_allowed? = Rails.configuration.x.economy_allowed == true

  # The gate as the full eval run writes it (Evals::EconomyGate): a mapping
  # whose economy_allowed is true or false, with the model and the effort the
  # boundary was measured on and the digests of the system prompt and the
  # tools the model read (PromptDigest). It allows the economy model only when
  # it says true for the economy route, the prompt and the tools as they are
  # now, since a run on another model, effort, prompt or tool set does not
  # speak for this one (the hunter's F2 on pull request #55). No file is "not
  # allowed", as before the first full run; a file that is anything else, or
  # cannot be read, is "not allowed" too, said once in a warning line, never
  # raised: a list or a scalar used to raise, so a forced economy answered 500
  # on every session and poll (review finding S6 of pull request #29). An
  # error is named by its class (threat model SR-30).
  def read_economy_allowed(path = ECONOMY_ALLOWED)
    gate = YAML.safe_load_file(path)
    return closed(path, "is not a mapping with economy_allowed true or false") unless gate.is_a?(Hash) && [ true, false ].include?(gate["economy_allowed"])
    return false unless gate["economy_allowed"]

    route = ModelPolicy.route("economy")
    unless gate.values_at("model", "effort") == [ route.model, route.effort ]
      return closed(path, "was written by a run on #{gate["model"].inspect} at #{gate["effort"].inspect} effort, " \
                          "not on the economy route's #{route.model} at #{route.effort}")
    end
    return true if gate.values_at("prompt", "tools") == [ PromptDigest.prompt, PromptDigest.tools ]

    closed(path, "was written for the system prompt #{gate["prompt"].inspect} and the tools #{gate["tools"].inspect}, " \
                 "not for the system prompt #{PromptDigest.prompt} and the tools #{PromptDigest.tools} the model reads now")
  rescue Errno::ENOENT
    false
  rescue Psych::Exception, ArgumentError, SystemCallError => e
    closed(path, "could not be read (#{e.class})")
  end

  def closed(path, why)
    Rails.logger.warn("budget: #{path} #{why}; the economy model may not serve")
    false
  end

  # The month's row. The call that opens it writes the month's first line,
  # since a new month is a change too: the resume of a month the cap paused
  # (review finding R2 of pull request #29).
  def month(at)
    BudgetState.for_month!(at).tap { |state| line(state, automatic(state.spent_usd)) if state.previously_new_record? }
  end

  def write_usage(turn, usage, cost)
    UsageRecord.create!(turn:, model: usage.model, input_tokens: usage.input_tokens, output_tokens: usage.output_tokens,
                        cache_creation_tokens: usage.cache_creation_tokens, cached_tokens: usage.cached_tokens,
                        cost_usd: cost)
  end

  # Written once by whichever read wins the conditional write.
  def record(state, automatic)
    written = BudgetState.where(id: state.id).where.not(automatic_mode: automatic)
                         .update_all(automatic_mode: automatic, updated_at: Time.current)
    return if written.zero?

    line(state, automatic)
  end

  # A forced mode that serves is named; a forced economy the eval run has not
  # allowed pauses the demo, which the line says (review finding R1 of pull
  # request #29).
  def line(state, automatic)
    forced = state.forced_mode
    note = if forced.nil? then ""
    elsif serving(forced, automatic) == forced then "; the forced #{forced} mode serves"
    else "; the forced #{forced} mode may not serve yet, so the demo pauses"
    end
    Rails.logger.warn(format("budget: %s's automatic mode is %s at US$ %.2f of its cap of US$ %.2f%s",
                             state.month, automatic, state.spent_usd, cap, note))
  end
  private_class_method :month, :write_usage, :record, :line, :closed
end
