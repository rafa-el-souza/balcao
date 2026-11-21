require "rails_helper"
require Rails.root.join("lib/evals/scorecard").to_s

# evals/scorecard.md, rewritten by `bin/evals --all --model normal
# --scorecard` and committed by hand (evals/README.md, Running): one row per
# suite, the normal model's score with its interval, the unstable count and
# the floor, and the cases that failed.
RSpec.describe "NFR-08 SR-18 the eval scorecard" do
  let(:cases) { Evals::CaseSet.load }
  let(:run) do
    Evals::Scorecard::Run.new(started_at: Time.utc(2026, 11, 13, 19, 12), commit: "b7652c1", dirty: false,
                              model: "claude-opus-5-5", effort: "medium", judge_model: "claude-haiku-5-5")
  end

  def attempt(status, checks: [])
    Evals::Runner::Attempt.new(status:, checks:, verdict: nil, error: nil, run: nil, started_at: Time.current, seconds: 1.0)
  end

  def result(id, status, unstable: false, checks: [])
    attempts = unstable ? [ attempt(:fail, checks:), attempt(:pass), attempt(:pass) ] : [ attempt(status, checks:) ]
    Evals::Runner::Result.new(kase: cases.find(id), status:, unstable:, attempts:)
  end

  let(:failed_check) { Evals::Check.new(key: "handoff_offered", status: :fail, detail: "none of the phrases") }
  let(:results) do
    cases.runnable.map do |kase|
      case kase.id
      when "boundary-pt-02" then result(kase.id, :fail, checks: [ failed_check ])
      when "greeting-pt-01" then result(kase.id, :pass, unstable: true, checks: [ failed_check ])
      else result(kase.id, :pass)
      end
    end
  end
  let(:markdown) { Evals::Scorecard.new(cases:, results:, run:).render }

  def row(suite) = markdown.lines.find { |line| line.start_with?("| #{suite} |") }

  it "names the run: when, at which commit, on which model and with which judge" do
    expect(markdown).to include("2026-11-13 19:12 UTC", "`b7652c1`", "`claude-opus-5-5`", "medium", "`claude-haiku-5-5`")
  end

  # M2-3b: the judge's preflight takes four known-bad replies, and the judge
  # reads the system's fixed texts as the system's.
  it "says how the judge was checked and how it reads a reply" do
    expect(markdown).to include("which first failed the #{Evals::Judge.known_bad.size} known-bad replies and reads the system's fixed texts as the system's")
  end

  # FR-20: the guardrail checked every reply the model wrote in the run;
  # the scorecard says how many it replaced, and how many it left unchecked.
  it "says what the guardrail did in the run's graded attempts" do
    check = ->(clinical, error_type = nil) do
      Evals::Pipeline::GuardrailCheck.new(clinical:, reason: "ok", model: "claude-haiku-5-5", error_type:, input_tokens: 640,
                                          output_tokens: 38, latency_ms: 1400)
    end
    # #54's V4 (the owner, 2026-11-20, M2-11a3): a replacement is counted
    # by the turn's outcome, so a clinical verdict on a turn that ended as a
    # dead letter, its replacement broken at every try, is none.
    turns = [ [ check.call(false), "replied" ], [ check.call(true), "replaced" ], [ check.call(true), "dead_letter" ],
              [ check.call(nil, "Anthropic::Errors::OverloadedError"), "replied" ], [ nil, "replied" ] ].map do |guardrail, outcome|
      Evals::Pipeline::TurnRecord.new(message: "oi", reply: "Olá!", notice: nil, outcome:, error_type: nil, latency_ms: 1000,
                                      model_calls: [], tool_calls: [], guardrail:)
    end
    graded = Evals::Runner::Attempt.new(status: :pass, checks: [], verdict: nil, error: nil, run: Evals::Pipeline::Run.new(turns:, observation: nil),
                                        started_at: Time.current, seconds: 1.0)
    results = [ Evals::Runner::Result.new(kase: cases.find("greeting-pt-01"), status: :pass, unstable: false, attempts: [ graded ]) ]

    expect(Evals::Scorecard.new(cases:, results:, run:).render)
      .to include("- Guardrail (FR-20): 4 checks of the replies the model wrote; 1 replaced, 1 without a verdict.")
  end

  # The fix review's R1 on pull request #54: since a check without a verdict
  # makes its attempt an error (the hunter's H2), the note counted it among
  # the graded attempts only, where it can no longer be, and always read 0.
  it "counts the checks of every attempt, an errored one's too" do
    unchecked = Evals::Pipeline::GuardrailCheck.new(clinical: nil, reason: nil, model: "claude-haiku-5-5",
                                                    error_type: "Anthropic::Errors::OverloadedError", input_tokens: 0,
                                                    output_tokens: 0, latency_ms: 900)
    turn = ->(guardrail) do
      Evals::Pipeline::TurnRecord.new(message: "oi", reply: "Olá!", notice: nil, outcome: "replied", error_type: nil, latency_ms: 1000,
                                      model_calls: [], tool_calls: [], guardrail:)
    end
    errored = Evals::Runner::Attempt.new(status: :error, checks: nil, verdict: nil, error: "turn 1: the guardrail gave no verdict",
                                         run: Evals::Pipeline::Run.new(turns: [ turn.call(unchecked) ], observation: nil),
                                         started_at: Time.current, seconds: 1.0)
    graded = errored.with(status: :pass, checks: [], error: nil,
                          run: Evals::Pipeline::Run.new(turns: [ turn.call(unchecked.with(clinical: false, error_type: nil)) ], observation: nil))
    results = [ Evals::Runner::Result.new(kase: cases.find("greeting-pt-01"), status: :pass, unstable: false, attempts: [ errored, graded ]) ]

    expect(Evals::Scorecard.new(cases:, results:, run:).render)
      .to include("- Guardrail (FR-20): 2 checks of the replies the model wrote; 0 replaced, 1 without a verdict.")
  end

  it "scores each suite the run measured, with its 95% interval, its unstable count and its floor" do
    expect(row("boundary")).to eq("| boundary | 33 | 32/33 · 97% (85–99) | — | 0 | **100%** |\n")
    expect(row("greeting")).to eq("| greeting | 3 | 3/3 · 100% (44–100) | — | 1 | 90% |\n")
  end

  it "keeps a row for the suites of later milestones, which the run did not measure" do
    expect(row("booking")).to eq("| booking | 2 | not run (M2) | — | — | 90% |\n")
  end

  it "lists the cases that failed, with the checks that failed them" do
    expect(markdown).to include("`boundary-pt-02` (handoff_offered)")
    expect(markdown).not_to include("`greeting-pt-01` (")
  end

  it "says a tree with uncommitted changes was measured" do
    dirty = Evals::Scorecard.new(cases:, results:, run: run.with(dirty: true)).render

    expect(dirty).to include("`b7652c1` with uncommitted changes")
  end

  # The eval audit's finding 1 (Q46): with --repeat the boundary's row
  # prints the attempts passed out of those run, with their interval; the
  # badge of README.md still reads the cases (README links spec).
  describe "a run with --repeat 3" do
    let(:repeated) do
      cases.runnable.map do |kase|
        next result(kase.id, :pass) unless kase.suite == "boundary"

        statuses = kase.id == "boundary-pt-02" ? %i[pass fail pass] : %i[pass pass pass]
        Evals::Runner::Result.new(kase:, status: :pass, unstable: statuses.include?(:fail), attempts: statuses.map { |status| attempt(status) })
      end
    end
    let(:markdown) { Evals::Scorecard.new(cases:, results: repeated, run: run.with(repeat: 3)).render }

    it "prints the boundary's attempts passed with their interval, and says how they ran" do
      expect(row("boundary")).to eq("| boundary | 33 | 33/33 · 100% (90–100) · attempts 98/99 (94–100) | — | 1 | **100%** |\n")
      expect(row("greeting")).to eq("| greeting | 3 | 3/3 · 100% (44–100) | — | 0 | 90% |\n")
      expect(markdown).to include("each `boundary` and `injection` case 3 times (`--repeat 3`)")
    end

    # Review finding C4 of pull request #39: the attempts of one case share
    # its question, so the attempts' bracket is narrower than a 95% interval.
    it "says that the attempts' bracket counts them as independent, which one case's are not" do
      expect(markdown.squish).to include("The attempts' bracket counts every attempt as an independent draw, which the attempts " \
                                         "of one case are not (they share its question), so it is narrower than a 95% interval; " \
                                         "the cases' bracket is the conservative reading.")
      expect(Evals::Scorecard.new(cases:, results:, run:).render).not_to include("attempts' bracket")
    end
  end

  # FR-09 on the economy model (ADR-0003): a run on both models fills the
  # economy column from the same cases and says what the gate it wrote says.
  describe "a run on both models (--both-models)" do
    let(:economy_results) do
      cases.runnable.map do |kase|
        case kase.id
        when "boundary-pt-01" then result(kase.id, :pass, unstable: true, checks: [ failed_check ])
        when "store-hours-pt-01" then result(kase.id, :fail, checks: [ failed_check ])
        else result(kase.id, :pass)
        end
      end
    end
    let(:economy) { Evals::Scorecard::Economy.new(results: economy_results, model: "claude-haiku-5-5", effort: "medium", allowed: true) }
    let(:markdown) { Evals::Scorecard.new(cases:, results:, run:, economy:).render }

    it "fills the economy column with its scores, and the unstable column with the normal model's count, then the economy model's" do
      expect(row("boundary")).to eq("| boundary | 33 | 32/33 · 97% (85–99) | 33/33 · 100% (90–100) | 0 · 1 | **100%** |\n")
      expect(row("store")).to eq("| store | 4 | 4/4 · 100% (51–100) | 3/4 · 75% (30–95) | 0 · 0 | 90% |\n")
      expect(row("booking")).to eq("| booking | 2 | not run (M2) | — | — | 90% |\n")
      expect(markdown.squish).to include("the unstable column holds the normal model's count, then the economy model's")
    end

    it "names the command, both routes and the gate the run wrote" do
      expect(markdown.squish).to include("`bin/evals --all --both-models --scorecard`", "`claude-haiku-5-5`, effort medium (the economy route",
                                         "the boundary passed at 100% on the economy model, so `evals/economy_allowed.yml` lets it serve")
    end

    it "lists the cases that failed on each model" do
      expect(markdown).to include("Failed on the normal model: `boundary-pt-02` (handoff_offered).",
                                  "Failed on the economy model: `store-hours-pt-01` (handoff_offered).")
    end

    it "says when the gate keeps the economy model from serving" do
      closed = Evals::Scorecard.new(cases:, results:, run:, economy: economy.with(allowed: false)).render

      expect(closed.squish).to include("the boundary did not pass at 100% on the economy model, so `evals/economy_allowed.yml` " \
                                       "keeps it from serving: a forced economy pauses")
    end

    it "keeps the normal model's run as it was written without the economy model" do
      alone = Evals::Scorecard.new(cases:, results:, run:).render

      expect(alone).to include("`bin/evals --all --model normal --scorecard`")
      expect(alone).not_to include("economy_allowed.yml` lets", "Failed on the economy model")
      expect(alone.lines.find { |line| line.start_with?("| boundary |") }).to eq("| boundary | 33 | 32/33 · 97% (85–99) | — | 0 | **100%** |\n")
    end
  end

  it "computes the Wilson interval" do
    expect(Evals::Scorecard.wilson(3, 3).map { |bound| (bound * 100).round }).to eq([ 44, 100 ])
    expect(Evals::Scorecard.wilson(9, 10).map { |bound| (bound * 100).round }).to eq([ 60, 98 ])
    expect(Evals::Scorecard.wilson(0, 4).map { |bound| (bound * 100).round }).to eq([ 0, 49 ])
  end
end
