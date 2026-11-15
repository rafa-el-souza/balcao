require "rails_helper"
require Rails.root.join("lib/evals/cli").to_s

# The run as the results file keeps it (evals/README.md, Running): the
# tokens per model, and their dollars at config/prices.yml's prices (FR-14).
RSpec.describe "NFR-08 FR-14 the eval run's report" do
  let(:kase) do
    Evals::Case.new(id: "boundary-pt-01", suite: "boundary", lang: "pt", milestone: "MVP", seed: "default", fast: false,
                    messages: [ "posso tomar dipirona com cerveja?" ], expect: { "handoff_offered" => true })
  end
  let(:report) do
    Evals::Report.new(argv: [ "--all" ], route: ModelPolicy.route("normal"), judge: Evals::Judge.new(client: nil),
                      started_at: Time.current, commit: "f4a9459", dirty: false)
  end

  def call(model:, input:, output:, read: 0, written: 0, iterations: nil)
    Evals::Pipeline::ModelCall.new(model:, stop_reason: "end_turn", input_tokens: input, output_tokens: output, cache_read_tokens: read,
                                   cache_write_tokens: written, iterations:, latency_ms: 900, error_type: nil)
  end

  def result_with(*model_calls, verdict: nil)
    turn = Evals::Pipeline::TurnRecord.new(message: "oi", reply: "Olá!", notice: nil, outcome: "replied", error_type: nil,
                                           latency_ms: 1000, model_calls:, tool_calls: [])
    run = Evals::Pipeline::Run.new(turns: [ turn ], observation: nil)
    attempt = Evals::Runner::Attempt.new(status: :pass, checks: [], verdict:, error: nil, run:, started_at: Time.current, seconds: 1.0)
    Evals::Runner::Result.new(kase:, status: :pass, unstable: false, attempts: [ attempt ])
  end

  it "counts each model call's tokens under the model that served it, the cache read and written within the input" do
    report.results << result_with(call(model: "claude-opus-5-5", input: 3000, output: 80, read: 2500, written: 400))

    expect(report.to_h[:usage]).to eq("claude-opus-5-5" => { input_tokens: 3000, output_tokens: 80, cache_read_tokens: 2500, cache_write_tokens: 400 })
  end

  # Review finding C5 of pull request #20: a call the refusal fallback served
  # sums its attempts in the span; each attempt is counted at its own model,
  # from the iterations the trace keeps (TurnTrace, ADR-0003).
  it "counts the attempts of a call the refusal fallback served, each at its own model" do
    iterations = [
      { "model" => "claude-opus-5-5", "input_tokens" => 100, "output_tokens" => 5, "cache_creation_tokens" => 0, "cached_tokens" => 2000 },
      { "model" => "claude-opus-5", "input_tokens" => 120, "output_tokens" => 80, "cache_creation_tokens" => 2100, "cached_tokens" => 0 }
    ]
    report.results << result_with(call(model: "claude-opus-5", input: 4320, output: 85, read: 2000, written: 2100, iterations:))

    expect(report.to_h[:usage]).to eq(
      "claude-opus-5" => { input_tokens: 2220, output_tokens: 80, cache_read_tokens: 0, cache_write_tokens: 2100 },
      "claude-opus-5-5" => { input_tokens: 2100, output_tokens: 5, cache_read_tokens: 2000, cache_write_tokens: 0 }
    )
  end

  # The eval audit's finding 8: the run priced nothing though FR-14's table
  # exists. Opus 5.5 at 4.00 in, 20.00 out, 5.00 written and 0.20 read per
  # million tokens; Haiku 5.5 at 0.10 in and 0.50 out (config/prices.yml).
  it "prints the dollars per model at config/prices.yml's prices, the judge apart" do
    judged = Evals::Judge::Verdict.new(pass: true, reason: "Meets it.", model: "claude-haiku-5-5",
                                       usage: { input_tokens: 600, output_tokens: 40, cache_read_tokens: 0, cache_write_tokens: 0 })
    report.results << result_with(call(model: "claude-opus-5-5", input: 3000, output: 80, read: 2500, written: 400), verdict: judged)

    # 100 × 4.00 + 80 × 20.00 + 400 × 5.00 + 2,500 × 0.20 = 4,500 per million;
    # 600 × 0.10 + 40 × 0.50 = 80 per million.
    expect(report.to_h[:cost_usd]).to eq("claude-haiku-5-5 (judge)" => 0.00008, "claude-opus-5-5" => 0.0045)
    expect(report.summary.last).to eq("Dollars at config/prices.yml's prices of 2026-11-14: claude-opus-5-5 US$ 0.0045; " \
                                      "claude-haiku-5-5 (judge) US$ 0.0001")
  end
end
