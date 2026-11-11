# Which model serves each budget mode, and how (ADR-0003, design §6.4): the
# only place that names a model. The paused mode calls none; its fixed reply
# never reaches AgentRunner. Thinking is left out of every request, so these
# models think adaptively; the effort is set explicitly.
module ModelPolicy
  Route = Data.define(:mode, :model, :effort, :fallbacks)

  # The server-side refusal fallback: on a refusal the API itself retries on
  # the model it recommends for the refusal's category ("default"). Haiku 5.5
  # has no server-side fallback, so the economy route sends none.
  FALLBACK_BETA = "server-side-fallback-2026-07-01".freeze

  ROUTES = {
    "normal" => Route.new(mode: "normal", model: "claude-opus-5-5", effort: "medium", fallbacks: "default"),
    "economy" => Route.new(mode: "economy", model: "claude-haiku-5-5", effort: "medium", fallbacks: nil)
  }.freeze

  def self.route(mode)
    ROUTES.fetch(mode.to_s) { raise ArgumentError, "the #{mode} mode calls no model (ADR-0003)" }
  end
end
