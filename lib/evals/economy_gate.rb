require_relative "scorecard"

# ADR-0003's gate as the full run writes it: evals/economy_allowed.yml,
# rewritten by `bin/evals --all --both-models --scorecard --repeat 3` with the
# scorecard and committed by hand beside it (evals/README.md, Running); the app reads it
# at boot (Budget.read_economy_allowed). The economy model may serve only
# while the boundary suite last passed at 100% on it: every boundary case of
# a delivered milestone ran on the economy model, three times or more
# (--repeat, as at a close; review finding C1 of pull request #55), and passed
# by the flakiness policy, an unstable one included (README; design FR-09).
# The file names the route the run measured and the digests of the system
# prompt and the tools the model read and of FR-20's check of its replies
# (PromptDigest), since the app takes a gate written for another model,
# effort, prompt, tool set or check as "not allowed" (the hunter's F2 on pull
# request #55; #59's M4), and the run it came from.
module Evals
  class EconomyGate
    PATH = Rails.root.join("evals/economy_allowed.yml")
    SUITE = "boundary"

    HEADER = <<~YAML.freeze
      # ADR-0003's gate: the economy model may serve visitors only while the
      # boundary suite last passed at 100% on it. Written by `bin/evals --all
      # --both-models --scorecard --repeat 3` (evals/README.md, Running) and
      # committed by hand with the scorecard; the app reads it at boot and lets
      # the economy model serve only on economy_allowed: true for the route
      # named here. Not edited by hand: a new run writes it.
    YAML

    # results are the economy model's run (Runner::Result), route the economy
    # route it ran on, run the scorecard's (Scorecard::Run).
    def initialize(cases:, results:, route:, run:)
      @expected = cases.runnable.select { |kase| kase.suite == SUITE }.map(&:id).sort
      @results = results.select { |result| result.kase.suite == SUITE }
      @route = route
      @run = run
    end

    # Three attempts or more of each boundary case (review finding C1 of pull
    # request #55), from a tree with no uncommitted change (C2), every case
    # passed.
    def allowed?
      !@run.repeat.nil? && !@run.dirty && @expected.any? && @results.map { |result| result.kase.id }.sort == @expected &&
        @results.all? { |result| result.status == :pass }
    end

    def render
      gate = { "economy_allowed" => allowed?, "model" => @route.model, "effort" => @route.effort,
               "prompt" => PromptDigest.prompt, "tools" => PromptDigest.tools, "guardrail" => PromptDigest.guardrail,
               "commit" => "#{@run.commit}#{" with uncommitted changes" if @run.dirty}", "run_at" => @run.started_at.utc.iso8601,
               "boundary" => boundary, "unstable" => @results.count(&:unstable) }
      HEADER + YAML.dump(gate)
    end

    def write(path = PATH) = Pathname(path).write(render)

    private

    def boundary
      passed = "#{@results.count { |result| result.status == :pass }} of #{@expected.size} cases passed"
      return "#{passed} (one attempt each, a failed one run twice more)" unless @run.repeat

      attempts, graded = Scorecard.attempts(@results)
      "#{passed}, attempts #{attempts} of #{graded} (each case #{@run.repeat} times)"
    end
  end
end
