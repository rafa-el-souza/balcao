require "rails_helper"

RSpec.describe "FR-12 trace event, one span in the shape of OpenTelemetry (ADR-0010)" do
  it "accepts a 128-bit trace id and 64-bit span ids in lowercase hex" do
    span = build(:trace_event, trace_id: "4bf92f3577b34da6a3ce929d0e0e4736",
                               span_id: "00f067aa0ba902b7", parent_span_id: "53995c3f42cd8ad8")

    expect(span).to be_valid
  end

  it "refuses ids of another length or case" do
    expect(build(:trace_event, trace_id: "4BF92F3577B34DA6A3CE929D0E0E4736")).not_to be_valid
    expect(build(:trace_event, span_id: "00f067aa0ba902")).not_to be_valid
    expect(build(:trace_event, parent_span_id: "xyz")).not_to be_valid
  end

  it "stores the span's attributes as JSON" do
    span = create(:trace_event, span_attributes: { "gen_ai.request.model" => "claude-opus-5-5" })

    expect(span.reload.span_attributes).to eq("gen_ai.request.model" => "claude-opus-5-5")
  end
end
