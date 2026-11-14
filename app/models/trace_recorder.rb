# The trace of one run of a turn (ADR-0010, FR-12): spans in the shape of
# OpenTelemetry, stored one row per span in trace_events and broadcast twice,
# on start and on finish, to the conversation's stream and to its trace
# page's (design §6.6), so the panel shows a model call while it runs.
#
#   recorder = TraceRecorder.new(turn)
#   root = recorder.start_span("balcao.turn", attributes: { "balcao.channel" => "web" })
#   call = recorder.start_span("anthropic.messages.create", parent: root)
#   call.finish(attributes: { "gen_ai.usage.output_tokens" => 80 })
#
# The trace id is 128 bits and the span id 64, random and in lowercase hex, as
# OpenTelemetry generates them; each run of a turn is a trace of its own.
# Span and attribute names are those the Anthropic SDK gives its own spans
# (gen_ai.* from the GenAI semantic conventions, anthropic.*), so the SDK's
# tracer can replace this class with the panel unchanged; the rest carry a
# balcao. prefix.
#
# A span carries only the attributes of ATTRIBUTES (threat model SR-12): an
# unknown name raises, so nothing reaches the trace by accident, and the
# system prompt, secrets and the visitor's identity have no attribute to
# travel in. Text is cut to 500 characters (FR-12), loses any NUL, which jsonb
# refuses (review finding C4 of pull request #10), and any byte that is not
# UTF-8. The trace never fails a turn: a span that cannot be stored or
# broadcast is logged by name and error class, never by its values, and the
# turn goes on.
class TraceRecorder
  ATTRIBUTES = Set.new(%w[
    balcao.channel balcao.message.source balcao.turn.mode balcao.turn.outcome
    balcao.command.name balcao.message.author balcao.message.characters balcao.latency_ms balcao.cost.usd
    balcao.system_prompt.characters balcao.system_prompt.sha256
    balcao.tool_result.characters balcao.tool_result.count balcao.tool_result.unit balcao.tool_result.refusal
    gen_ai.operation.name gen_ai.provider.name gen_ai.request.model gen_ai.request.max_tokens
    gen_ai.request.reasoning.level gen_ai.response.model anthropic.message.stop_reason
    gen_ai.usage.input_tokens gen_ai.usage.output_tokens
    gen_ai.usage.cache_read.input_tokens gen_ai.usage.cache_write.input_tokens anthropic.usage.iterations
    gen_ai.tool.name gen_ai.tool.type gen_ai.tool.call.arguments anthropic.tool_result.content
    error.type
  ]).freeze
  MAX_TEXT = 500
  INTERRUPTED = "interrupted".freeze

  attr_reader :trace_id

  # Finishes the spans an earlier run of the turn left open (a crash, a
  # deploy), marked as interrupted, before the turn runs again.
  def self.close_interrupted(turn)
    TraceEvent.where(turn_id: turn.id, finished_at: nil).find_each do |event|
      event.update!(finished_at: Time.current, span_attributes: event.span_attributes.merge("error.type" => INTERRUPTED))
      broadcast(turn.conversation, payload(event.attributes.symbolize_keys.merge(attributes: event.span_attributes)))
    end
  end

  def self.streams(conversation) = [ "conversation:#{conversation.id}", "trace:#{conversation.trace_token}" ]

  def self.broadcast(conversation, payload)
    streams(conversation).each { |stream| ActionCable.server.broadcast(stream, payload) }
  rescue StandardError => e
    Rails.logger.error("trace: span #{payload.dig(:span, :name)} not broadcast: #{e.class}")
  end

  # The span as the streams and the endpoints carry it; its turn lets the
  # panel group the rows of a conversation by turn (design §10, note of
  # 2026-11-12).
  def self.payload(span)
    { type: "span",
      span: { turn_id: span[:turn_id], trace_id: span[:trace_id], span_id: span[:span_id], parent_span_id: span[:parent_span_id],
              name: span[:name], attributes: span[:attributes], started_at: span[:started_at]&.iso8601(3),
              finished_at: span[:finished_at]&.iso8601(3) } }
  end

  def self.clean(attributes)
    attributes.to_h.each_with_object({}) do |(key, value), clean|
      key = key.to_s
      raise ArgumentError, "#{key} is not a trace attribute (threat model SR-12)" unless ATTRIBUTES.include?(key)
      next if value.nil?

      clean[key] = value_of(value)
    end
  end

  def self.value_of(value)
    case value
    when String then text(value)
    when Integer, Float, true, false then value
    when Array then value.map { |item| value_of(item) }
    when Hash then value.to_h { |key, item| [ text(key.to_s), value_of(item) ] }
    else text(value.to_s)
    end
  end

  def self.text(value)
    value = value.dup.force_encoding(Encoding::UTF_8).scrub.delete("\u0000")
    value.length > MAX_TEXT ? "#{value[0, MAX_TEXT - 1]}…" : value
  end

  # OpenTelemetry's ids are random and never all zeros.
  def self.random_id(bytes)
    loop do
      id = SecureRandom.hex(bytes)
      return id unless id.match?(/\A0+\z/)
    end
  end

  def initialize(turn)
    @turn = turn
    @conversation = turn.conversation
    @trace_id = self.class.random_id(16)
    @open = []
  end

  def start_span(name, parent: nil, attributes: {}, started_at: nil)
    span = Span.new(self, name:, span_id: self.class.random_id(8), parent_span_id: parent&.span_id, turn_id: @turn.id,
                          started_at: started_at || Time.current, attributes: self.class.clean(attributes))
    write(span) do
      span.event = TraceEvent.create!(turn_id: @turn.id, trace_id:, span_id: span.span_id, parent_span_id: span.parent_span_id,
                                      name:, span_attributes: span.attributes, started_at: span.started_at)
    end
    self.class.broadcast(@conversation, span.payload)
    @open << span
    span
  end

  # Span#finish calls this; a span finishes once.
  def finish(span, attributes)
    attributes = self.class.clean(attributes)
    return if span.finished_at

    @open.delete(span)
    span.attributes = span.attributes.merge(attributes)
    span.finished_at = Time.current
    write(span) { span.event&.update!(span_attributes: span.attributes, finished_at: span.finished_at) }
    self.class.broadcast(@conversation, span.payload)
  end

  # Finishes the spans still open, the innermost first, when a turn breaks.
  def abandon(error_type)
    @open.reverse_each.to_a.each { |span| span.finish(attributes: { "error.type" => error_type }) }
  end

  # A savepoint, so that a failed write leaves a caller's transaction usable.
  def write(span)
    TraceEvent.transaction(requires_new: true) { yield }
  rescue StandardError => e
    Rails.logger.error("trace: span #{span.name} not recorded: #{e.class}")
  end

  class Span
    attr_reader :name, :span_id, :parent_span_id, :turn_id, :started_at
    attr_accessor :attributes, :finished_at, :event

    def initialize(recorder, name:, span_id:, parent_span_id:, turn_id:, started_at:, attributes:)
      @recorder = recorder
      @name = name
      @span_id = span_id
      @parent_span_id = parent_span_id
      @turn_id = turn_id
      @started_at = started_at
      @attributes = attributes
    end

    def trace_id = @recorder.trace_id

    def finish(attributes: {}) = @recorder.finish(self, attributes)

    def payload
      TraceRecorder.payload(turn_id:, trace_id:, span_id:, parent_span_id:, name:, attributes:, started_at:, finished_at:)
    end
  end
end
