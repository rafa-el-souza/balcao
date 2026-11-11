# Model responses built from the Anthropic SDK's own types (design §6.4), so
# a fake reply has the production shape by construction: a field the SDK
# renames or requires breaks these builders, not a turn in production. Each
# builder returns what FakeModel serves: the HTTP status and the JSON body the
# API would send, which the SDK then parses back into its types.
module ModelResponses
  Beta = Anthropic::Models::Beta

  module_function

  # A request body as it goes on the wire, with string keys and values: the
  # SDK hands middleware the body as its caller built it, symbols and all.
  def wire(body) = JSON.parse(JSON.generate(body))

  def usage(input: 1200, output: 80, cache_write: 0, cache_read: 3000, iterations: nil)
    Beta::BetaUsage.new(
      input_tokens: input, output_tokens: output,
      cache_creation_input_tokens: cache_write, cache_read_input_tokens: cache_read,
      iterations:, cache_creation: nil, fallback_credit: nil, inference_geo: nil,
      output_tokens_details: nil, server_tool_use: nil, service_tier: :standard, speed: nil
    )
  end

  def iteration(model:, input: 1200, output: 80, cache_write: 0, cache_read: 0, fallback: false)
    klass = fallback ? Beta::BetaFallbackMessageIterationUsage : Beta::BetaMessageIterationUsage
    klass.new(
      type: fallback ? :fallback_message : :message, model:,
      input_tokens: input, output_tokens: output,
      cache_creation_input_tokens: cache_write, cache_read_input_tokens: cache_read, cache_creation: nil
    )
  end

  def text(text) = Beta::BetaTextBlock.new(type: :text, text:, citations: nil)

  def thinking = Beta::BetaThinkingBlock.new(type: :thinking, thinking: "", signature: "sig-#{SecureRandom.hex(4)}")

  def tool_use(name, input, id: "toolu_#{SecureRandom.hex(6)}")
    Beta::BetaToolUseBlock.new(type: :tool_use, id:, name:, input:)
  end

  def refusal_details
    Beta::BetaRefusalStopDetails.new(
      type: :refusal, category: nil, explanation: nil, fallback_credit_token: nil,
      fallback_has_prefill_claim: nil, recommended_model: nil
    )
  end

  def message(content:, stop_reason: :end_turn, model: "claude-opus-5-5", usage: self.usage, stop_details: nil)
    message = Beta::BetaMessage.new(
      id: "msg_#{SecureRandom.hex(8)}", type: :message, role: :assistant, model:, content:,
      stop_reason:, stop_sequence: nil, stop_details:, usage:,
      container: nil, context_management: nil, diagnostics: nil
    )
    { status: 200, body: message.to_h }
  end

  def reply(text, **) = message(content: [ thinking, self.text(text) ], **)

  def tool_turn(*tool_uses, **) = message(content: [ thinking, *tool_uses ], stop_reason: :tool_use, **)

  def refusal(**) = message(content: [], stop_reason: :refusal, stop_details: refusal_details, **)

  # The error responses of NFR-03, one per type: 429 and 529 as the API sends
  # them, and a timeout, which never gets a response.
  ERRORS = {
    rate_limit: [ 429, Anthropic::Models::BetaRateLimitError, :rate_limit_error ],
    overloaded: [ 529, Anthropic::Models::BetaOverloadedError, :overloaded_error ]
  }.freeze

  def error(kind)
    return { timeout: true } if kind == :timeout

    status, klass, type = ERRORS.fetch(kind)
    body = Anthropic::Models::BetaErrorResponse.new(
      type: :error, error: klass.new(type:, message: type.to_s.tr("_", " ")), request_id: "req_#{SecureRandom.hex(6)}"
    )
    { status:, body: body.to_h }
  end
end
