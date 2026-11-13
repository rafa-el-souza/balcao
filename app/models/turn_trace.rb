# The spans of a turn's model calls and tool calls (FR-12, ADR-0010), from
# the events AgentRunner yields as they happen: a model call's span opens
# when the call starts and closes when its answer or its error arrives; a
# tool call's span is written when the call returns, dated back by its
# latency, with its result's length and, for a list, what it lists and how
# many, taken before the trace cuts the text (FR-12); a refusal also carries
# its reason code, which tells it from a failure (both are the SDK's
# tool_error). Names and attributes are the ones the Anthropic SDK gives its own
# spans. The system prompt is summarised by its size and a digest (threat
# model SR-12): a changed prompt shows, its text never does.
class TurnTrace
  MODEL_CALL = "anthropic.messages.create".freeze
  TOOL_CALL = "anthropic.custom_tool_use".freeze

  def self.prompt_summary(prompt = SystemPrompt.current)
    @prompt_summary ||= { "balcao.system_prompt.characters" => prompt.length,
                          "balcao.system_prompt.sha256" => Digest::SHA256.hexdigest(prompt)[0, 16] }.freeze
  end

  def initialize(recorder, root)
    @recorder = recorder
    @root = root
  end

  def on(event)
    case event
    when AgentRunner::ModelStarted then @model_call = start_model_call(event)
    when AgentRunner::ModelCall then finish_model_call(event)
    when AgentRunner::ToolCall then tool_call(event)
    end
  end

  private

  def start_model_call(event)
    @recorder.start_span(MODEL_CALL, parent: @root, attributes: {
      "gen_ai.operation.name" => "chat", "gen_ai.provider.name" => "anthropic",
      "gen_ai.request.model" => event.model, "gen_ai.request.reasoning.level" => event.effort,
      "gen_ai.request.max_tokens" => AgentRunner::MAX_TOKENS, **self.class.prompt_summary
    })
  end

  def finish_model_call(call)
    span = @model_call || start_model_call(call)
    @model_call = nil
    span.finish(attributes: {
      "gen_ai.response.model" => (call.model unless call.error), "anthropic.message.stop_reason" => call.stop_reason,
      "balcao.latency_ms" => call.latency_ms, "error.type" => call.error, **usage(call.usage)
    })
  end

  # Summed over the attempts of a call a fallback model served, each listed
  # with its own model as it came (FR-14 prices them apart). The input counts
  # the cache read and written, as the SDK's own tracer does (anthropic 2.8,
  # Helpers::Tracing): the API's input_tokens leaves them out, and the panel's
  # input is the whole prompt (design §10, note of 2026-11-12).
  def usage(entries)
    return {} if entries.empty?

    cached = entries.sum(&:cached_tokens)
    written = entries.sum(&:cache_creation_tokens)
    totals = {
      "gen_ai.usage.input_tokens" => entries.sum(&:input_tokens) + cached + written,
      "gen_ai.usage.output_tokens" => entries.sum(&:output_tokens),
      "gen_ai.usage.cache_read.input_tokens" => cached, "gen_ai.usage.cache_write.input_tokens" => written
    }
    totals["anthropic.usage.iterations"] = entries.map(&:to_h) if entries.size > 1
    totals
  end

  def tool_call(call)
    span = @recorder.start_span("#{TOOL_CALL} #{call.name}", parent: @root, started_at: Time.current - (call.latency_ms / 1000.0),
                                                              attributes: {
                                                                "gen_ai.operation.name" => "execute_tool", "gen_ai.tool.name" => call.name,
                                                                "gen_ai.tool.type" => "function",
                                                                "gen_ai.tool.call.arguments" => JSON.generate(TraceRecorder.value_of(call.input))
                                                              })
    span.finish(attributes: { "anthropic.tool_result.content" => call.output, "balcao.latency_ms" => call.latency_ms,
                              "balcao.tool_result.characters" => call.characters, "balcao.tool_result.unit" => call.unit,
                              "balcao.tool_result.count" => call.count, "balcao.tool_result.refusal" => call.refusal,
                              "error.type" => ("tool_error" if call.is_error) })
  end
end
