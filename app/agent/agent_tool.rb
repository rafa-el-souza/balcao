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

  # The report runs after the call and outside the rescue of its bugs: a
  # handler that raises (the trace's insert failing after a reservation was
  # stored) neither turns a stored result into a failure for the model nor
  # reports the call twice, and its message never reaches the model (review
  # finding C3 of pull request #9). A report that fails is logged and skipped.
  def call(input)
    @gate&.call
    started = monotonic
    output, error, tally = run(input)
    report(input, error ? error.message : output, !error.nil?, started, tally)
    raise error if error

    output
  end

  def perform(input) = raise(NotImplementedError, "#{self.class} must implement perform")

  # What a result that is a list holds and how many, for the trace ("2
  # resultados", FR-12): { unit: "products", count: 2 }, read from the result
  # before it is encoded, so before the trace cuts its text. Nil for a single
  # fact; a tool whose result is a list says so.
  def tally(_result) = nil

  private

  # The output, or the error the model reads: a refusal's own, FAILED for a bug.
  def run(input)
    result = perform(input)
    [ encode(result), nil, tally_of(result) ]
  rescue Error => e
    [ nil, e ]
  rescue StandardError => e
    Rails.logger.error("tool #{name} failed: #{e.class}: #{e.message}")
    [ nil, Error.new(FAILED) ]
  end

  def encode(output) = output.is_a?(String) ? output : JSON.generate(output)

  # A count that cannot be taken is no count; the result still reaches the model.
  def tally_of(result)
    tally(result)
  rescue StandardError => e
    Rails.logger.error("tool #{name}: the result was not counted: #{e.class}")
    nil
  end

  def report(input, output, is_error, started, tally)
    return unless @on_call

    @on_call.call(AgentRunner::ToolCall.new(
      name:, input: JSON.parse(JSON.generate(input.to_h)), output:, is_error:,
      latency_ms: ((monotonic - started) * 1000).round, characters: output.to_s.length,
      unit: tally&.fetch(:unit), count: tally&.fetch(:count)
    ))
  rescue StandardError => e
    Rails.logger.error("tool #{name}: the call was not reported: #{e.class}")
  end

  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end
