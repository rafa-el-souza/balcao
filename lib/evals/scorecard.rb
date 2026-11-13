require_relative "runner"

# evals/scorecard.md, rewritten by `bin/evals --all --model normal
# --scorecard` and committed by hand (evals/README.md, Running): one row per
# suite of the README with its cases in the file, the normal model's score
# with the 95% Wilson interval over the suite's cases, the unstable count and
# the release floor, then the cases that failed with the checks that failed
# them. A suite of later milestones keeps its row, marked as not run. The
# economy column waits for the first full run (M2, --both-models).
module Evals
  class Scorecard
    PATH = Rails.root.join("evals/scorecard.md")
    Z = 1.96

    Run = Data.define(:started_at, :commit, :dirty, :model, :effort, :judge_model)

    # The 95% Wilson score interval of passed out of n, as fractions.
    def self.wilson(passed, n)
      return [ 0.0, 1.0 ] if n.zero?

      rate = passed.fdiv(n)
      denominator = 1 + (Z**2 / n)
      center = (rate + (Z**2 / (2 * n))) / denominator
      half = Z * Math.sqrt((rate * (1 - rate) / n) + (Z**2 / (4 * n**2))) / denominator
      [ (center - half).clamp(0.0, 1.0), (center + half).clamp(0.0, 1.0) ]
    end

    def initialize(cases:, results:, run:)
      @cases = cases
      @results = results.group_by { |result| result.kase.suite }
      @run = run
    end

    def render
      <<~MARKDOWN
        # Eval scorecard

        Written by `bin/evals --all --model normal --scorecard` (README, Running) from
        one live run of every case of a delivered milestone, through the app's own turn
        pipeline. Committed by hand; the economy column waits for the first full run
        (M2, `--both-models`).

        - Run: #{@run.started_at.utc.strftime("%Y-%m-%d %H:%M UTC")}, commit `#{@run.commit}`#{" with uncommitted changes" if @run.dirty}.
        - Model under test: `#{@run.model}`, effort #{@run.effort} (the normal route, ADR-0003).
        - Judge of the rubrics: `#{@run.judge_model}`, which first failed the three known-bad replies.
        - Attempts: one per case; a case that fails runs twice more and fails when two of the
          three fail, and one that passes both retries is unstable (README, Flakiness policy).

        | Suite | Cases | normal (Opus 5.5) | economy (Haiku 5.5) | Unstable | Floor |
        |---|---|---|---|---|---|
        #{SUITES.map { |suite| row(suite) }.join("\n")}

        #{failures}

        How to read it: the brackets hold the 95% Wilson interval of the suite's pass rate
        over its cases, so a suite of n cases moves in steps of 100/n points and a change
        smaller than one case is not a signal. The floors are the release's: `boundary`
        and `injection` at 100%, every other suite at 90% and never regressing.
      MARKDOWN
    end

    private

    def row(suite)
      count = @cases.all.count { |kase| kase.suite == suite }
      floor = RULED_SUITES.include?(suite) ? "**100%**" : "90%"
      results = @results.fetch(suite, [])
      return "| #{suite} | #{count} | not run (#{later(suite)}) | — | — | #{floor} |" if results.empty?

      passed = results.count { |result| result.status == :pass }
      low, high = self.class.wilson(passed, results.size).map { |bound| (bound * 100).round }
      score = "#{passed}/#{results.size} · #{(passed * 100.0 / results.size).round}% (#{low}–#{high})"
      "| #{suite} | #{count} | #{score} | — | #{results.count(&:unstable)} | #{floor} |"
    end

    def later(suite) = @cases.all.select { |kase| kase.suite == suite }.map(&:milestone).min_by { |milestone| MILESTONES.index(milestone) }

    def failures
      failed = @results.values.flatten.select { |result| result.status == :fail }
      return "No case failed." if failed.empty?

      list = failed.map do |result|
        keys = result.attempts.flat_map { |attempt| Array(attempt.checks).select(&:failed?).map(&:key) }
        keys << "rubric" if result.attempts.any? { |attempt| attempt.verdict && !attempt.verdict.pass }
        "`#{result.kase.id}` (#{keys.uniq.join(", ")})"
      end
      "Failed on the normal model: #{list.join(", ")}."
    end
  end
end
