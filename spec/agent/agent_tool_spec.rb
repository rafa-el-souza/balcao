require "rails_helper"

RSpec.describe "SR-16 AgentTool, the base of the attendant's tools (design §6.3)" do
  let(:turn) { create(:turn) }
  let(:calls) { [] }

  def tool(klass) = klass.new(turn:, on_call: ->(call) { calls << call })

  def input(text = "dipirona") = SpecTools::EchoInput.new(text:)

  it "is named after its class and sent strict, with no property the schema does not name" do
    request = { tools: [ tool(SpecTools::Echo) ] }
    Anthropic::Helpers::Messages.distill_input_schema_models!(request, strict: nil)

    expect(request[:tools].first.to_h).to include(name: "echo", strict: true,
                                                  input_schema: include(additionalProperties: false, required: [ "text" ]))
  end

  it "holds the turn the runner gave it (SR-16)" do
    expect(tool(SpecTools::Echo).turn).to eq(turn)
  end

  it "answers the model in JSON" do
    expect(JSON.parse(tool(SpecTools::Echo).call(input))).to eq("echo" => "dipirona", "turn_id" => turn.id)
  end

  it "reports each call with its input, output and time" do
    tool(SpecTools::Echo).call(input)

    expect(calls).to contain_exactly(have_attributes(name: "echo", input: { "text" => "dipirona" }, is_error: false,
                                                     output: include("dipirona"), latency_ms: a_value >= 0))
  end

  it "passes a refusal's message to the model as an error result" do
    expect { tool(SpecTools::Refuse).call(input) }.to raise_error(AgentTool::Error, "no such topic")
    expect(calls.first).to have_attributes(is_error: true, output: "no such topic")
  end

  it "keeps a bug's message from the model and logs it" do
    allow(Rails.logger).to receive(:error)

    expect { tool(SpecTools::Crash).call(input) }.to raise_error(AgentTool::Error, AgentTool::FAILED)
    expect(calls.first).to have_attributes(is_error: true, output: AgentTool::FAILED)
    expect(Rails.logger).to have_received(:error).with(/crash.*RuntimeError/)
  end
end

RSpec.describe "SR-16 AgentTool reports outside the rescue of a tool's bugs (review finding C3 of pull request #9)" do
  let(:turn) { create(:turn) }
  let(:input) { SpecTools::EchoInput.new(text: "dipirona") }

  before { allow(Rails.logger).to receive(:error) }

  it "answers the model with the tool's result, reported once, when the handler raises after a successful call" do
    reports = []
    handler = lambda do |call|
      reports << call
      raise ActiveRecord::StatementInvalid, "PG::Error: secret host 10.0.0.5"
    end

    output = SpecTools::Echo.new(turn:, on_call: handler).call(input)

    expect(JSON.parse(output)).to eq("echo" => "dipirona", "turn_id" => turn.id)
    expect(reports.size).to eq(1)
    expect(Rails.logger).to have_received(:error).with(/echo.*not reported.*ActiveRecord::StatementInvalid/)
    expect(Rails.logger).not_to have_received(:error).with(/secret host/)
  end

  it "keeps a refusal's own message for the model when the handler raises" do
    handler = ->(_call) { raise "handler bug" }

    expect { SpecTools::Refuse.new(turn:, on_call: handler).call(input) }
      .to raise_error(AgentTool::Error, "no such topic")
  end

  it "never sends the handler's message to the model when a buggy tool's report raises" do
    handler = ->(_call) { raise "handler bug: secret" }

    expect { SpecTools::Crash.new(turn:, on_call: handler).call(input) }
      .to raise_error(AgentTool::Error, AgentTool::FAILED)
  end
end
