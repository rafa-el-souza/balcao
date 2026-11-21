# The budget (FR-14, threat model SR-02, ADR-0003, ADR-0012): the ledger that
# charges every model call to the calendar month in São Paulo, and the mode
# the turn reads before any model call.
#
# - The ledger: each attempt of a model call is a usage record at the price
#   table's prices (Prices), and its cost is added to the month's spend in
#   the same transaction, under the month row's lock, so concurrent turns add
#   up. The spend lives on the month's row, which outlives the seven-day purge
#   of the usage records (FR-15). The day's spend in São Paulo is kept beside
#   it on the same row, since a day never straddles two months there, and the
#   charge that opens a new day starts it over (the daily slice, ADR-0012).
# - The mode: a forced mode wins until it is released (the kill switch, the
#   runbook's command until M2-10's console); otherwise the automatic one,
#   paused from the cap on, economy from 70 % of the cap on, and economy until
#   midnight once the day's spend reaches its slice of the cap (cap ÷ 30 ×
#   1.5), normal below them (FR-14, M3-1). Economy serves only on the full
#   eval run's word (ADR-0003), the committed evals/economy_allowed.yml, read
#   once at boot (config/initializers/budget.rb); without it an economy
#   pauses: a forced one with the forced pause's text, the month's with the
#   month's, the day's until midnight with the day's (Status#daily), and the
#   month goes on, so the next day starts in normal.
# - The record: the read that finds the automatic mode changed writes it into
#   the month's row and one log line, whatever changed it (a charge past a
#   threshold, a cap a deploy lowered or raised, the next day or month),
#   saying which forced mode serves when one wins (review finding S3 of pull
#   request #29) and that the demo pauses when the gate keeps an economy from
#   serving (#55's L4). A read that finds the month paused at its cap, or
#   an economy the closed gate turned into a pause, writes the operator's
#   alert if it is missing, once for what it reports, and its job sends it
#   through the bot (OperatorAlert, threat model SR-35).
#
# The gate reads the mode once, when a turn starts: turns already running when
# the cap is reached finish, so the month may end a few turns past its cap
# (design §10, PR-16's note).
module Budget
  ECONOMY_ALLOWED = Rails.root.join("evals/economy_allowed.yml")
  # ADR-0003: the month moves to the economy model at 70 % of its cap.
  ECONOMY_AT = BigDecimal("0.7")

  module_function

  # The month's cap in US dollars: BUDGET_CAP_USD in each destination
  # (config/environments/production.rb), ADR-0003's default elsewhere
  # (config/application.rb).
  def cap = Rails.configuration.x.budget_cap_usd

  # ADR-0012: the day's slice of the month's cap, cap ÷ 30 × 1.5.
  def slice = cap * BigDecimal("1.5") / 30

  # The mode that serves, whether a mode the operator forced made it, and
  # whether a pause lasts until midnight: a forced pause, or a forced economy
  # the eval run has not allowed, answers with a text of its own, the cap's
  # pause and the month's economy the gate keeps closed with the month's
  # (FR-14; the owner, 2026-11-15), the day's slice the gate keeps closed with
  # the day's (daily).
  Status = Data.define(:mode, :forced, :daily) do
    def initialize(mode:, forced:, daily: false) = super
  end

  # The mode the spend makes, and what made it: "cap", "month" (70 % of the
  # cap), "day" (the day's slice), or nil for normal.
  Automatic = Data.define(:mode, :cause)

  def status(at = Time.current)
    state = month(at)
    automatic = automatic(state, at)
    record(state, automatic, at) unless state.automatic_mode == automatic.mode
    wanted = state.forced_mode || automatic.mode
    mode = serving(state.forced_mode, automatic.mode)
    line(state, automatic, at) if mode != wanted && !held?(state, automatic, at)
    alert(state, automatic, mode, at) if alerting?(state, automatic, mode)
    Status.new(mode:, forced: !state.forced_mode.nil?, daily: mode == "paused" && state.forced_mode.nil? && automatic.cause == "day")
  end

  def mode(at = Time.current) = status(at).mode

  # The mode that serves: a forced one wins, and economy only on the eval
  # run's word.
  def serving(forced, automatic)
    mode = forced || automatic
    mode == "economy" && !economy_allowed? ? "paused" : mode
  end

  def automatic(state, at)
    spent = state.spent_usd
    if spent >= cap then Automatic.new(mode: "paused", cause: "cap")
    elsif spent >= cap * ECONOMY_AT then Automatic.new(mode: "economy", cause: "month")
    elsif day_spent(state, at) >= slice then Automatic.new(mode: "economy", cause: "day")
    else Automatic.new(mode: "normal", cause: nil)
    end
  end

  # The day's spend on the month's row, nothing for a day no charge has
  # opened yet: the day of São Paulo.
  def day_spent(state, at) = state.day == at.in_time_zone.to_date ? state.day_spent_usd : 0

  # FR-14's kill switch until the console has it (M2-10, which will call this
  # too): forces a mode on the month's row, or releases it with nil, writes
  # the month's line, which names a forced mode that may not serve (a forced
  # economy the gate keeps closed pauses the demo), and answers what serves
  # now. The operator used to force the row itself, and no line said that a
  # forced economy paused (the hunter's F1 on pull request #55).
  def force!(mode, at = Time.current)
    state = month(at)
    state.update!(forced_mode: mode&.to_s)
    line(state, automatic(state, at), at)
    status(at)
  end

  # Charges a turn's model calls, one usage record per attempt
  # (AgentRunner::Usage), and answers what they cost: to the month and to the
  # day, under the month row's lock, which reloads it, so the day a charge
  # starts over is the one the database holds.
  def charge!(turn, usages, at: Time.current)
    return 0 if usages.empty?

    costs = usages.map { |usage| [ usage, Prices.cost_usd(usage).round(8) ] }
    total = costs.sum(&:last)
    state = month(at)
    day = at.in_time_zone.to_date
    state.with_lock do
      costs.each { |usage, cost| write_usage(turn, usage, cost) }
      state.update!(spent_usd: state.spent_usd + total, day:, day_spent_usd: day_spent(state, at) + total)
    end
    total
  end

  # ADR-0003's gate as the boot read it: nothing but a true lets economy serve.
  def economy_allowed? = Rails.configuration.x.economy_allowed == true

  # The gate as the full eval run writes it (Evals::EconomyGate): a mapping
  # whose economy_allowed is true or false, with the model and the effort the
  # boundary was measured on and the digests of the system prompt, the tools
  # and what the history gave the model back, and of FR-20's check of its
  # replies (PromptDigest). It allows the economy model only when it says
  # true for the economy route, the prompt, the tools, the history and the
  # check as they are now, since a run on another model, effort, prompt, tool
  # set, history or check does not speak for this one (the hunter's F2 on
  # pull request #55; #59's M4; the close's XF-C4 and #60's C3). No file, a
  # file that is anything else, or one that cannot be read, is "not allowed",
  # said once in a warning line, never raised: a list or a scalar used to
  # raise, so a forced economy answered 500 on every session and poll (review
  # finding S6 of pull request #29); and since the first full run the gate is
  # committed, so no file is a fault too (the hunter's F3). An error is named
  # by its class (threat model SR-30). Only the file's read and parse are
  # rescued: a bug of the route's lookup or of a digest raises, at boot,
  # where CI's boot specs see it first, rather than reading as a file that
  # cannot be read (#55's F4 and #60's H-B6, the owner, 2026-11-20).
  def read_economy_allowed(path = ECONOMY_ALLOWED)
    gate = begin
      YAML.safe_load_file(path)
    rescue Errno::ENOENT
      return closed(path, "is missing")
    rescue Psych::Exception, ArgumentError, SystemCallError => e
      return closed(path, "could not be read (#{e.class})")
    end
    return closed(path, "is not a mapping with economy_allowed true or false") unless gate.is_a?(Hash) && [ true, false ].include?(gate["economy_allowed"])
    return false unless gate["economy_allowed"]

    route = ModelPolicy.route("economy")
    unless gate.values_at("model", "effort") == [ route.model, route.effort ]
      return closed(path, "was written by a run on #{gate["model"].inspect} at #{gate["effort"].inspect} effort, " \
                          "not on the economy route's #{route.model} at #{route.effort}")
    end
    serving = [ PromptDigest.prompt, PromptDigest.tools, PromptDigest.guardrail, PromptDigest.history ]
    return true if gate.values_at("prompt", "tools", "guardrail", "history") == serving

    closed(path, "was written for the system prompt #{gate["prompt"].inspect}, the tools #{gate["tools"].inspect}, " \
                 "FR-20's check #{gate["guardrail"].inspect} and the history #{gate["history"].inspect}, not for the system prompt " \
                 "#{serving[0]}, the tools #{serving[1]}, the check #{serving[2]} and the history #{serving[3]} that serve now")
  end

  def closed(path, why)
    Rails.logger.warn("budget: #{path} #{why}; the economy model may not serve")
    false
  end

  # The month's row. The call that opens it writes the month's first line,
  # since a new month is a change too: the resume of a month the cap paused
  # (review finding R2 of pull request #29).
  def month(at)
    BudgetState.for_month!(at).tap { |state| line(state, automatic(state, at), at) if state.previously_new_record? }
  end

  def write_usage(turn, usage, cost)
    UsageRecord.create!(turn:, model: usage.model, input_tokens: usage.input_tokens, output_tokens: usage.output_tokens,
                        cache_creation_tokens: usage.cache_creation_tokens, cached_tokens: usage.cached_tokens,
                        cost_usd: cost)
  end

  # Written once by whichever read wins the conditional write.
  def record(state, automatic, at)
    written = BudgetState.where(id: state.id).where.not(automatic_mode: automatic.mode)
                         .update_all(automatic_mode: automatic.mode, updated_at: Time.current)
    return if written.zero?

    line(state, automatic, at)
  end

  # The operator's alert of each cause (OperatorAlert): the cap, whatever
  # serves; and the month's economy and the day's slice that ADR-0003's
  # closed gate turns into pauses, never a pause the operator forced (review
  # findings C1 = H1 and H4 of pull request #63).
  ALERTS = { "cap" => "budget_cap", "month" => "budget_month", "day" => "budget_day" }.freeze

  # The operator's alert the budget's state calls for now, as its kind and
  # key, or nil: the one OperatorChat.link! sends again when it failed for
  # want of a chat, never an earlier one or one whose pause is over (the fix
  # review's R1 and R2 on pull request #63). It reads the month's row and
  # writes nothing: a month no turn has opened calls for none.
  def due_alert(at = Time.current)
    state = BudgetState.find_by(month: at.in_time_zone.strftime("%Y-%m")) or return nil
    automatic = automatic(state, at)
    return unless alerting?(state, automatic, serving(state.forced_mode, automatic.mode))

    kind = ALERTS.fetch(automatic.cause)
    [ kind, OperatorAlert.budget_key(kind, month: state.month, day: at.in_time_zone.to_date, cap:) ]
  end

  def alerting?(state, automatic, mode)
    automatic.cause == "cap" || (state.forced_mode.nil? && mode == "paused" && ALERTS.key?(automatic.cause))
  end

  # FR-14: the month at its cap tells the operator, once a month and cap,
  # through the bot (OperatorAlert, threat model SR-35), and so does a pause
  # the closed gate makes, once a month and cap or once a day and cap. Any
  # read while the pause holds writes the alert if it is missing, not only
  # the read that moved the month's mode, so a month paused before this code,
  # or by a container without it in a deploy's window, gets one too (review
  # finding C3 = H11 of pull request #63); once a process knows it is written,
  # it asks no more. The mode that serves is the spend's whether or not the
  # alert is written, so its write never breaks the read, a turn's before its
  # model call among them: one error line a process and alert names the
  # failure by its class (SR-30), and a later read tries again (C7 = H7).
  def alert(state, automatic, mode, at)
    kind = ALERTS.fetch(automatic.cause)
    key = OperatorAlert.budget_key(kind, month: state.month, day: at.in_time_zone.to_date, cap:)
    return if @alerted&.include?([ kind, key ])

    unless OperatorAlert.exists?(kind:, key:)
      written = OperatorAlert.budget!(kind, key:, state:, cap:, slice:, day_spent: day_spent(state, at), serving: mode,
                                            day: at.in_time_zone.to_date)
      written.deliver_later if written.previously_new_record?
    end
    (@alerted ||= Set.new) << [ kind, key ]
  rescue StandardError => e
    return if @unwritten&.include?([ kind, key ])

    (@unwritten ||= Set.new) << [ kind, key ]
    Rails.logger.error("budget: the operator's alert #{kind} #{key} not written, #{e.class}; a later read tries again")
  end

  # A forced mode that serves is named; an economy the eval run has not
  # allowed pauses the demo, which the line says, a forced one (review finding
  # R1 of pull request #29) and an automatic one, with when it ends (#55's L4),
  # once a process and month, or day, for the read that finds it (held?): a
  # deploy whose gate reads closed under a month in economy writes no other
  # line, and the boot's names the gate, not the pause (review finding H-B3 of
  # pull request #60).
  def line(state, automatic, at)
    forced = state.forced_mode
    note = if serving(forced, automatic.mode) == (forced || automatic.mode) then forced ? "; the forced #{forced} mode serves" : ""
    else
      (@held ||= Set.new) << held_key(state, automatic, at)
      if forced then "; the forced #{forced} mode may not serve yet, so the demo pauses"
      else "; the economy model may not serve yet, so the demo pauses #{automatic.cause == "day" ? "until midnight" : "until the month ends"}"
      end
    end
    Rails.logger.warn(format("budget: %s's automatic mode is %s at US$ %.2f of its cap of US$ %.2f and US$ %.2f of the day's slice of US$ %.2f%s",
                             state.month, automatic.mode, state.spent_usd, cap, day_spent(state, at), slice, note))
  end

  def held?(state, automatic, at) = @held&.include?(held_key(state, automatic, at))

  # A forced mode's pause once a month; an automatic economy's once a month,
  # or once a day for the day's slice.
  def held_key(state, automatic, at)
    forced = state.forced_mode
    [ state.month, forced, (automatic.cause unless forced), (at.in_time_zone.to_date if forced.nil? && automatic.cause == "day") ]
  end
  private_class_method :month, :write_usage, :record, :alerting?, :alert, :line, :held?, :held_key, :closed, :day_spent
end
