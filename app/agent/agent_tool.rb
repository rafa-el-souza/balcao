# The base of the attendant's tools (design §6.3, threat model SR-16). A tool is
# a plain Ruby object the SDK's tool runner calls with arguments it has already
# parsed against the tool's strict schema; the runner creates one per turn and
# gives it the turn, so the visitor, the conversation and the turn never come
# from the model. Subclasses declare `doc` and `input_schema` and implement
# `perform`, whose result reaches the model as JSON. The tool's name is its
# class name in snake case (GetStoreInfo is get_store_info).
#
# A tool refuses with AgentTool::Error, whose message is for the model ("no
# such topic"). Any other exception is a bug: it is logged, and the model
# gets FAILED, never the exception's message. Before every call the runner's
# gate may refuse it, which is how no call beyond the turn's sixth ever runs
# (threat model SR-20).
class AgentTool < Anthropic::BaseTool
  FAILED = "The tool failed. Tell the visitor you could not check this right now.".freeze

  class Error < StandardError; end

  tool_options strict: true

  attr_reader :turn

  def initialize(turn:, on_call: nil, gate: nil)
    super()
    @turn = turn
    @on_call = on_call
    @gate = gate
  end

  def name = self.class.name.demodulize.underscore

  def call(input)
    @gate&.call
    measure(input)
  end

  def perform(input) = raise(NotImplementedError, "#{self.class} must implement perform")

  private

  def measure(input)
    started = monotonic
    output = encode(perform(input))
    report(input, output, false, started)
    output
  rescue Error => e
    report(input, e.message, true, started)
    raise
  rescue StandardError => e
    Rails.logger.error("tool #{name} failed: #{e.class}: #{e.message}")
    report(input, FAILED, true, started)
    raise Error, FAILED
  end

  def encode(output) = output.is_a?(String) ? output : JSON.generate(output)

  def report(input, output, is_error, started)
    @on_call&.call(AgentRunner::ToolCall.new(
      name:, input: JSON.parse(JSON.generate(input.to_h)), output:, is_error:,
      latency_ms: ((monotonic - started) * 1000).round
    ))
  end

  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end
