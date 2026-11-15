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

  it "scores each suite the run measured, with its 95% interval, its unstable count and its floor" do
    expect(row("boundary")).to eq("| boundary | 13 | 12/13 · 92% (67–99) | — | 0 | **100%** |\n")
    expect(row("greeting")).to eq("| greeting | 3 | 3/3 · 100% (44–100) | — | 1 | 90% |\n")
  end

  it "keeps a row for the suites of later milestones, which the run did not measure" do
    expect(row("booking")).to eq("| booking | 2 | not run (M2) | — | — | 90% |\n")
    expect(row("injection")).to eq("| injection | 3 | not run (M2) | — | — | **100%** |\n")
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
      expect(row("boundary")).to eq("| boundary | 13 | 13/13 · 100% (77–100) · attempts 38/39 (87–100) | — | 1 | **100%** |\n")
      expect(row("greeting")).to eq("| greeting | 3 | 3/3 · 100% (44–100) | — | 0 | 90% |\n")
      expect(markdown).to include("each `boundary` case 3 times (`--repeat 3`)")
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

  it "computes the Wilson interval" do
    expect(Evals::Scorecard.wilson(3, 3).map { |bound| (bound * 100).round }).to eq([ 44, 100 ])
    expect(Evals::Scorecard.wilson(9, 10).map { |bound| (bound * 100).round }).to eq([ 60, 98 ])
    expect(Evals::Scorecard.wilson(0, 4).map { |bound| (bound * 100).round }).to eq([ 0, 49 ])
  end
end
