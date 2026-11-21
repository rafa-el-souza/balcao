require "active_support/testing/time_helpers"
require_relative "recording"
require_relative "runner"

# bin/evals --recorded (evals/README.md, Running): each selected case once,
# through the app's own pipeline (Evals::Pipeline) on the normal route, with
# its recording in the model's place (Evals::Recording): no key, no network,
# no judge. The run happens at the recording's time, so what the system adds
# by the clock reads as it read then. A case fails when its recording is
# missing or stale, when the run asks the model for more or fewer answers
# than the recording holds, when the API or the harness broke the run as a
# live run would count it (Runner#broken), when a rule check fails, and when
# its rubric's verdict was recorded for another reply or fails. Every case
# runs once: a replay is the same each time, so a retry would say nothing.
module Evals
  class Replay
    include ActiveSupport::Testing::TimeHelpers

    def initialize(pipeline:, checks:, route:, dir: Recording::DIR)
      @pipeline = pipeline
      @checks = checks
      @route = route
      @dir = dir
    end

    # The results, as a live run's (Runner::Result, one attempt each),
    # yielding each as its case ends.
    def call(cases)
      recordings = cases.to_h { |kase| [ kase.id, Recording.load(kase, @dir) ] }
      verdicts = Recording::Verdicts.new(recordings.values.compact)
      cases.map { |kase| replay(kase, recordings[kase.id], verdicts).tap { |result| yield result if block_given? } }
    end

    private

    def replay(kase, recording, verdicts)
      return failed(kase, "no recording at #{Recording.path(kase, @dir)}") unless recording

      stale = recording.stale(kase)
      if stale.any?
        return failed(kase, "stale: #{stale.join(", ")} changed since the recording (commit #{recording.data["commit"]}); " \
                            "record it again with bin/evals --record --fast")
      end

      started_at = Time.current
      started = AgentRunner::MONOTONIC.call
      fake = FakeModel.new(recording.responses)
      run = travel_to(recording.recorded_at) { AgentRunner.with_client(fake.client) { @pipeline.run(kase) } }
      graded(kase, run, fake, recording, verdicts).then do |status, checks, verdict|
        attempt = Runner::Attempt.new(status:, checks:, verdict:, error: nil, run:, started_at:, seconds: AgentRunner::MONOTONIC.call - started)
        Runner::Result.new(kase:, status:, unstable: false, attempts: [ attempt ])
      end
    rescue StandardError => e
      failed(kase, "the harness raised #{e.class}: #{e.message}", run:)
    end

    def graded(kase, run, fake, recording, verdicts)
      replayed = []
      replayed << check("#{fake.left} of the recording's #{recording.responses.size} answers were never asked for") if fake.left.positive?
      broken = broken(run)
      replayed << check(broken) if broken
      checks = broken ? [] : @checks.run(kase, run.observation)
      checks += replayed
      verdict = nil
      if kase.rubric && checks.none?(&:failed?)
        begin
          verdict = verdicts.grade(rubric: kase.rubric, parts: run.observation.parts)
        rescue Recording::Verdicts::Stale => e
          checks << check("#{e.message}; record it again with bin/evals --record --fast")
        end
      end
      [ checks.none?(&:failed?) && (verdict.nil? || verdict.pass) ? :pass : :fail, checks, verdict ]
    end

    # A request the API refused (Runner::Fatal) breaks a replay as any other.
    def broken(run)
      Runner.new(pipeline: @pipeline, checks: @checks, judge: nil, route: @route).broken(run)
    rescue Runner::Fatal => e
      e.message
    end

    def check(detail) = Check.new(key: "recording", status: :fail, detail:)

    def failed(kase, detail, run: nil)
      attempt = Runner::Attempt.new(status: :fail, checks: [ check(detail) ], verdict: nil, error: nil, run:, started_at: Time.current, seconds: 0.0)
      Runner::Result.new(kase:, status: :fail, unstable: false, attempts: [ attempt ])
    end
  end
end
