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
    mode = state.forced_mode || automatic(state.spent_usd)
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
    paused = state.with_lock do
      costs.each { |usage, cost| record(turn, usage, cost) }
      before = state.spent_usd
      state.update!(spent_usd: before + total, automatic_mode: automatic(before + total))
      automatic(before) != "paused" && state.automatic_paused?
    end
    Rails.logger.warn("budget: #{state.month} reached its cap of US$ #{format("%.2f", cap)}: paused") if paused
    total
  end

  def economy_allowed?
    ECONOMY_ALLOWED.exist? && YAML.safe_load_file(ECONOMY_ALLOWED)&.fetch("economy_allowed", false) == true
  end

  def record(turn, usage, cost)
    UsageRecord.create!(turn:, model: usage.model, input_tokens: usage.input_tokens, output_tokens: usage.output_tokens,
                        cache_creation_tokens: usage.cache_creation_tokens, cached_tokens: usage.cached_tokens,
                        cost_usd: cost)
  end
  private_class_method :record
end
