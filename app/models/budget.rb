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
#   Economy serves only on the full eval run's word (ADR-0003), which no file
#   holds before M2, so a forced economy pauses. Economy at 70 %, the daily
#   slice and the operator's notification arrive at M3 (design §9.1).
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

  def mode(at = Time.current)
    state = BudgetState.for_month!(at)
    automatic = automatic(state.spent_usd)
    record(state, automatic) unless state.automatic_mode == automatic
    mode = state.forced_mode || automatic
    mode == "economy" && !economy_allowed? ? "paused" : mode
  end

  def automatic(spent) = spent >= cap ? "paused" : "normal"

  # Charges a turn's model calls, one usage record per attempt
  # (AgentRunner::Usage), and answers what they cost.
  def charge!(turn, usages, at: Time.current)
    return 0 if usages.empty?

    costs = usages.map { |usage| [ usage, Prices.cost_usd(usage).round(8) ] }
    total = costs.sum(&:last)
    state = BudgetState.for_month!(at)
    state.with_lock do
      costs.each { |usage, cost| write_usage(turn, usage, cost) }
      state.update!(spent_usd: state.spent_usd + total)
    end
    total
  end

  def economy_allowed?
    ECONOMY_ALLOWED.exist? && YAML.safe_load_file(ECONOMY_ALLOWED)&.fetch("economy_allowed", false) == true
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

    serving = state.forced_mode ? "; the forced #{state.forced_mode} mode serves" : ""
    Rails.logger.warn(format("budget: %s's automatic mode is %s at US$ %.2f of its cap of US$ %.2f%s",
                             state.month, automatic, state.spent_usd, cap, serving))
  end
  private_class_method :write_usage, :record
end
