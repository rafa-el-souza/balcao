require "rails_helper"

# M3's CI furniture (design §9.2, NFR-08): the checks that are CI steps
# rather than examples are found in the workflow here, so a step dropped or
# moved fails a spec instead of leaving the gate silently. The jobs keep the
# names the branch protection requires: a job renamed would leave a required
# check that never reports.
RSpec.describe "NFR-08 the CI workflow runs M3's furniture in the jobs the branch protection requires" do
  let(:workflow) { YAML.safe_load_file(Rails.root.join(".github/workflows/ci.yml")) }
  let(:jobs) { workflow.fetch("jobs") }

  def steps(job) = jobs.fetch(job).fetch("steps")
  def step(job, run) = steps(job).find { |step| step["run"].to_s.include?(run) }

  it "keeps the four jobs, by the names the branch protection requires" do
    expect(jobs.transform_values { |job| job["name"] }).to eq(
      "ruby_static" => "Ruby: RuboCop, Brakeman, bundler-audit", "ruby_test" => "Ruby: RSpec",
      "web" => "Web: ESLint, Prettier, types, Vitest, build, npm audit", "secret_scan" => "Secrets: gitleaks"
    )
  end

  it "holds no secret and asks for no permission beyond reading the contents (threat model SR-29)" do
    expect(workflow.to_s).not_to include("secrets.")
    expect(workflow.fetch("permissions")).to eq({})
    expect(jobs.values.map { |job| job["permissions"] }).to all(eq("contents" => "read"))
  end

  # evals/README.md, Running: the fast subset's recordings replayed with no
  # key, after the suite, on its test database.
  it "replays the recorded fast evals with no key, after the whole suite" do
    replay = step("ruby_test", "bin/evals --recorded")
    whole = steps("ruby_test").index { |step| step["run"] == "bundle exec rspec" }

    expect(replay["run"]).to eq("bin/evals --recorded")
    expect(steps("ruby_test").index(replay)).to be > whole
    expect(jobs.fetch("ruby_test").to_s).not_to include("ANTHROPIC")
    expect(Rails.root.join("config/ci.rb").read).to include('"bin/evals --recorded"')
  end

  describe "SR-25 SR-38 the static secrets check and the hooks check" do
    it "run as their own step before the whole suite" do
      check = step("ruby_test", "-e SR-25")
      whole = steps("ruby_test").index { |step| step["run"] == "bundle exec rspec" }

      expect(check["run"]).to include("bundle exec rspec spec/deploy", '-e "runs no repository hook"')
      expect(check["name"]).to include("SR-25", "SR-38")
      expect(steps("ruby_test").index(check)).to be < whole
    end
  end
end
