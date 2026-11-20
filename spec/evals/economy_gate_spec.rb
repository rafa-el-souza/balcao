require "rails_helper"
require Rails.root.join("lib/evals/economy_gate").to_s

# ADR-0003's gate as the full eval run writes it: evals/economy_allowed.yml,
# committed by hand with the scorecard and read by the app at boot (Budget).
# The economy model may serve only while the boundary suite last passed at
# 100% on it (FR-09 on both models from M2).
RSpec.describe "FR-09 FR-14 SR-02 SR-18 the economy model's gate, as the full eval run writes it" do
  let(:cases) { Evals::CaseSet.load }
  let(:route) { ModelPolicy.route("economy") }
  let(:run) do
    Evals::Scorecard::Run.new(started_at: Time.utc(2026, 11, 20, 4, 0), commit: "ec17b12", dirty: false, model: route.model,
                              effort: route.effort, judge_model: route.model, repeat: 3)
  end
  let(:dir) { Pathname(Dir.mktmpdir("economy-gate")) }

  after { FileUtils.remove_entry(dir) }

  def result(kase, status: :pass, unstable: false)
    attempts = Array.new(Evals::Runner::REPEATED_SUITES.include?(kase.suite) ? 3 : 1) do |index|
      Evals::Runner::Attempt.new(status: unstable && index.zero? ? :fail : status, checks: [], verdict: nil, error: nil, run: nil,
                                 started_at: Time.current, seconds: 1.0)
    end
    Evals::Runner::Result.new(kase:, status:, unstable:, attempts:)
  end

  let(:passed) { cases.runnable.map { |kase| result(kase) } }

  def gate(results, run: self.run) = Evals::EconomyGate.new(cases:, results:, route:, run:)

  def with(id, **changes) = passed.map { |result| result.kase.id == id ? result(result.kase, **changes) : result }

  it "allows the economy model when every boundary case of a delivered milestone passed on it" do
    expect(gate(passed).allowed?).to be(true)
  end

  it "keeps it from serving when a boundary case failed or ended in error, or did not run" do
    expect(gate(with("boundary-pt-02", status: :fail)).allowed?).to be(false)
    expect(gate(with("boundary-pt-02", status: :error)).allowed?).to be(false)
    expect(gate(passed.reject { |result| result.kase.id == "boundary-pt-02" }).allowed?).to be(false)
    expect(gate(passed.reject { |result| result.kase.suite == "boundary" }).allowed?).to be(false)
  end

  # Review finding C1 of pull request #55 (FR-09): at a close each boundary
  # case runs three times and the 100% rests on those attempts, but a run
  # without --repeat graded each case once and wrote a gate that let the
  # economy model serve.
  it "FR-09 keeps the economy model from serving on a run that graded each boundary case once" do
    once = cases.runnable.map do |kase|
      attempt = Evals::Runner::Attempt.new(status: :pass, checks: [], verdict: nil, error: nil, run: nil, started_at: Time.current, seconds: 1.0)
      Evals::Runner::Result.new(kase:, status: :pass, unstable: false, attempts: [ attempt ])
    end
    path = dir.join("economy_allowed.yml")

    gate(once, run: run.with(repeat: nil)).write(path)
    expect(Budget.read_economy_allowed(path)).to be(false)
  end

  it "takes an unstable case as passed, as the flakiness policy does, and counts it" do
    unstable = gate(with("boundary-pt-02", unstable: true))

    expect(unstable.allowed?).to be(true)
    expect(YAML.safe_load(unstable.render)).to include("unstable" => 1, "boundary" => "13 of 13 cases passed, attempts 38 of 39 (each case 3 times)")
  end

  it "writes a file the app reads back as its verdict, naming the route and the run it came from" do
    path = dir.join("economy_allowed.yml")

    gate(passed).write(path)
    expect(Budget.read_economy_allowed(path)).to be(true)
    expect(YAML.safe_load_file(path)).to eq(
      "economy_allowed" => true, "model" => route.model, "effort" => route.effort, "commit" => "ec17b12",
      "run_at" => "2026-11-20T04:00:00Z", "boundary" => "13 of 13 cases passed, attempts 39 of 39 (each case 3 times)", "unstable" => 0
    )
    expect(path.read).to start_with("# ADR-0003's gate")

    allow(Rails.logger).to receive(:warn)
    gate(with("boundary-pt-02", status: :fail), run: run.with(repeat: nil, dirty: true)).write(path)
    expect(Budget.read_economy_allowed(path)).to be(false)
    expect(Rails.logger).not_to have_received(:warn)
    expect(YAML.safe_load_file(path)).to include("commit" => "ec17b12 with uncommitted changes",
                                                 "boundary" => "12 of 13 cases passed (one attempt each, a failed one run twice more)")
  end
end
