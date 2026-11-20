require_relative "pipeline"
require_relative "judge"

# The live runs' policy (evals/README.md, Flakiness policy). A case passes
# when its first attempt passes; one that fails is run twice more and fails
# when it fails two of the three; one that failed once and passed both
# retries passes as unstable. With --repeat N, as at a close, each boundary
# and injection case runs N times, every attempt graded, a pass too: two
# failures fail it and one makes it unstable (design FR-09; the eval audit's
# finding 1; for injection, whose floor is 100% too, design §10, M2-4).
#
# An attempt the API or the harness broke is an error, never the attendant's
# failure (the eval audit's infra-versus-model rule): a turn whose model call
# failed after the SDK's own retries or ran out of its sixty seconds
# (model_error, deadline), a message that got no reply, a turn run in a mode
# other than the route's (the budget paused it, or the gate stayed closed on
# the economy route), a call served by a model other than the route's (the
# refusal fallback of ADR-0003 is production's own path, and its iterations
# show it), FR-20's check that gave no verdict, a judge that broke, and the
# harness raising. An errored attempt is run again apart from the graded
# ones; the third error ends the case in error. An error no retry can mend
# (the API refusing the key or the request) stops the run.
module Evals
  class Runner
    GRADED = 3
    ERRORS = 3
    # The suites --repeat applies to (README, Flakiness policy), and the
    # attempts it takes: with fewer than three, one failure would leave a
    # single pass, which the usual policy never takes as a pass; more than
    # ten is a typo's cost (the finder's note 2 on pull request #39).
    REPEATED_SUITES = %w[boundary injection].freeze
    REPEAT = (3..10)
    INFRA_OUTCOMES = %w[model_error deadline].freeze
    FATAL_ERRORS = %w[
      Anthropic::Errors::AuthenticationError Anthropic::Errors::PermissionDeniedError Anthropic::Errors::NotFoundError
      Anthropic::Errors::BadRequestError Anthropic::Errors::UnprocessableEntityError
    ].freeze

    # status is :pass, :fail or :error; checks and verdict are nil for an error.
    Attempt = Data.define(:status, :checks, :verdict, :error, :run, :started_at, :seconds)
    Result = Data.define(:kase, :status, :unstable, :attempts)

    # An error no retry mends. It carries the attempt it broke and, once the
    # case has it, the case's result with every attempt so far, so the
    # results file keeps them and their tokens (review finding C3 of pull
    # request #20).
    class Fatal < StandardError
      attr_reader :attempt, :result

      def initialize(message, attempt: nil, result: nil)
        super(message)
        @attempt = attempt
        @result = result
      end
    end

    # Seconds to wait before running again an attempt the API broke: the
    # SDK's retries back off within the turn already, so a new attempt waits
    # longer, with jitter.
    RETRY_WAIT = (5.0..10.0)

    def initialize(pipeline:, checks:, judge:, route:, repeat: nil, clock: AgentRunner::MONOTONIC, pause: ->(seconds) { sleep(seconds) })
      raise ArgumentError, "repeat takes #{REPEAT.min} to #{REPEAT.max} attempts, not #{repeat}" if repeat && !REPEAT.cover?(repeat)

      @pipeline = pipeline
      @checks = checks
      @judge = judge
      @route = route
      @repeat = repeat
      @clock = clock
      @pause = pause
    end

    # How many graded attempts the case runs come what may: --repeat's for a
    # case of a repeated suite, nil for the usual policy.
    def repeat_for(kase) = (@repeat if REPEATED_SUITES.include?(kase.suite))

    # Runs the cases in order, yielding each result as its case ends.
    def call(cases)
      cases.map { |kase| run_case(kase).tap { |result| yield result if block_given? } }
    end

    private

    def run_case(kase)
      attempts = []
      repeat = repeat_for(kase)
      loop do
        @pause.call(rand(RETRY_WAIT)) if attempts.last&.status == :error
        attempts << attempt(kase)
        status = decided(attempts, repeat)
        next unless status

        failed = attempts.any? { |attempt| attempt.status == :fail }
        return Result.new(kase:, status:, unstable: status == :pass && failed, attempts:)
      end
    rescue Fatal => e
      raise Fatal.new(e.message, result: Result.new(kase:, status: :error, unstable: false, attempts: [ *attempts, e.attempt ].compact))
    end

    def decided(attempts, repeat)
      return :error if attempts.count { |attempt| attempt.status == :error } >= ERRORS

      passes = attempts.reject { |attempt| attempt.status == :error }.map { |attempt| attempt.status == :pass }
      return repeated(passes, repeat) if repeat
      return :pass if passes == [ true ]
      return :fail if passes.count(false) >= 2

      :pass if passes.size == GRADED
    end

    # Undecided until every one of the repeat's attempts is graded; then two
    # failures fail the case.
    def repeated(passes, repeat)
      return if passes.size < repeat

      passes.count(false) >= 2 ? :fail : :pass
    end

    def attempt(kase)
      started_at = Time.current
      started = @clock.call
      run = @pipeline.run(kase)
      status, checks, verdict, error = graded(kase, run)
      Attempt.new(status:, checks:, verdict:, error:, run:, started_at:, seconds: @clock.call - started)
    rescue StandardError => e
      fatal = e.is_a?(Fatal) || FATAL_ERRORS.include?(e.class.name)
      error = e.is_a?(Fatal) ? e.message : "#{e.class}: #{e.message}"
      attempt = Attempt.new(status: :error, checks: nil, verdict: nil, error:, run:, started_at:, seconds: @clock.call - started)
      raise Fatal.new("#{error}; no retry mends it, so the run stops", attempt:) if fatal

      attempt
    end

    def graded(kase, run)
      broken = broken(run)
      return [ :error, nil, nil, broken ] if broken

      checks = @checks.run(kase, run.observation)
      # The judge can only turn a pass into a failure, so it reads the reply
      # when every rule check passed; a judge that broke after a rule failed
      # would turn that failure into an error (review finding S2 of pull
      # request #20). It reads the reply in its authors' parts (M2-3b).
      verdict = @judge.grade(rubric: kase.rubric, parts: run.observation.parts) if kase.rubric && checks.none?(&:failed?)
      passed = checks.none?(&:failed?) && (verdict.nil? || verdict.pass)
      [ passed ? :pass : :fail, checks, verdict, nil ]
    end

    # FR-20's check that gave no verdict lets the reply go unchecked, which
    # production allows (threat model R4) and a run must not grade: the
    # attempt is an error, and a request the API refuses stops the run (the
    # hunter's H2 on pull request #54).
    def broken(run)
      run.turns.each_with_index do |turn, index|
        fatal!(turn.error_type, "turn #{index + 1}") if turn.error_type
        return "turn #{index + 1}: #{turn.outcome} (#{turn.error_type || "no error class"})" if INFRA_OUTCOMES.include?(turn.outcome)
        return "turn #{index + 1}: no reply (#{turn.outcome})" if turn.reply.blank?
        return "turn #{index + 1}: ran in the #{turn.mode} mode, not #{@route.mode}" if turn.mode && turn.mode != @route.mode

        unchecked = turn.guardrail&.error_type
        fatal!(unchecked, "turn #{index + 1}'s guardrail") if unchecked
        return "turn #{index + 1}: the guardrail gave no verdict (#{unchecked})" if unchecked

        rerouted = turn.model_calls.find { |call| call.model != @route.model && call.iterations.blank? }
        return "turn #{index + 1}: served by #{rerouted.model}, not #{@route.model}" if rerouted
      end
      nil
    end

    def fatal!(error_type, where)
      raise Fatal, "#{where}: #{error_type}" if FATAL_ERRORS.include?(error_type)
    end
  end
end
