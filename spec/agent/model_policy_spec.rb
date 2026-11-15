require "rails_helper"

RSpec.describe "ADR-0003 ADR-0021 model policy (FR-14, NFR-01, design §6.4)" do
  # ADR-0021 (M4-2): at low effort the turn took about a tenth less time and
  # the evals passed as at medium.
  it "serves the normal mode on Opus 5.5 at low effort with the server-side refusal fallback" do
    route = ModelPolicy.route("normal")

    expect(route).to have_attributes(model: "claude-opus-5-5", effort: "low", fallbacks: "default")
  end

  it "serves the economy mode on Haiku 5.5 at medium effort, which has no server-side fallback" do
    route = ModelPolicy.route(:economy)

    expect(route).to have_attributes(model: "claude-haiku-5-5", effort: "medium", fallbacks: nil)
  end

  it "has no model for the paused mode, which answers with a fixed reply" do
    expect { ModelPolicy.route("paused") }.to raise_error(ArgumentError, /paused/)
  end

  it "names the beta header the fallback needs" do
    expect(ModelPolicy::FALLBACK_BETA).to eq("server-side-fallback-2026-07-01")
  end
end
