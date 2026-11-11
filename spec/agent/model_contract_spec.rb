require "rails_helper"

# The fake model's contract with the SDK (design §6.4): responses built from
# the SDK's own types, served by FakeModel as the API would serve them, parsed
# back by the SDK and accepted by AgentRunner. A stop reason or an error class
# that a new SDK version adds fails here first.
RSpec.describe "NFR-03 model contract: the fake and AgentRunner accept the SDK's types (design §6.4, SR-19, SR-20)" do
  include ModelResponses

  let(:turn) { create(:turn) }

  def run_with(*responses)
    fake = FakeModel.new(responses)
    [ AgentRunner.new(client: fake.client, tools: [ SpecTools::Echo ], clock: FakeClock.new).run(turn), fake ]
  end

  describe "every stop reason" do
    # What the turn becomes for each stop reason; the ones the SDK's runner
    # resumes on its own are followed by a reply.
    outcomes = {
      end_turn: :replied,
      stop_sequence: :replied,
      tool_use: :replied,
      pause_turn: :replied,
      compaction: :replied,
      max_tokens: :incomplete,
      model_context_window_exceeded: :incomplete,
      refusal: :refused
    }.freeze

    def first_response(stop_reason)
      case stop_reason
      when :tool_use then tool_turn(tool_use("echo", { "text" => "x" }))
      when :refusal then refusal
      when :end_turn, :stop_sequence then reply("[pt] Pronto.", stop_reason:)
      # A paused or compacted step is resumed by the SDK's runner; Balcão has
      # no server tools, so here it is a step with no output yet.
      when :pause_turn, :compaction then message(content: [ thinking ], stop_reason:)
      else message(content: [ thinking, text("[pt] Pront") ], stop_reason:)
      end
    end

    it "classifies every stop reason the SDK knows" do
      expect(Anthropic::Models::Beta::BetaStopReason.values).to match_array(outcomes.keys)
    end

    Anthropic::Models::Beta::BetaStopReason.values.each do |stop_reason|
      it "turns #{stop_reason} into #{outcomes.fetch(stop_reason, "an outcome")}" do
        result, = run_with(first_response(stop_reason), reply("[pt] Pronto."))

        expect(result.outcome).to eq(outcomes.fetch(stop_reason))
        expect(result.text).to(outcomes[stop_reason] == :replied ? eq("Pronto.") : be_nil)
      end
    end
  end

  it "reads tool_use blocks, runs the tool and sends its result back with the call's id" do
    call = tool_use("echo", { "text" => "dipirona" }, id: "toolu_contract")
    result, fake = run_with(tool_turn(call), reply("[pt] Temos."))

    sent = wire(fake.requests.last.body)["messages"].last
    expect(sent["role"]).to eq("user")
    expect(sent["content"].first).to include("type" => "tool_result", "tool_use_id" => "toolu_contract", "is_error" => false)
    expect(result.tool_calls.first).to have_attributes(name: "echo", input: { "text" => "dipirona" })
  end

  it "returns the thinking blocks of a tool turn unchanged, as preserved thinking requires" do
    turn_with_thinking = tool_turn(tool_use("echo", { "text" => "x" }))
    _, fake = run_with(turn_with_thinking, reply("[pt] Pronto."))

    echoed = wire(fake.requests.last.body)["messages"][-2]["content"].first
    expect(echoed).to include("type" => "thinking", "signature" => turn_with_thinking[:body][:content].first[:signature])
  end

  it "reads the usage fields" do
    result, = run_with(reply("[pt] Pronto.", usage: usage(input: 11, output: 22, cache_write: 33, cache_read: 44)))

    expect(result.model_calls.first.usage.first)
      .to have_attributes(input_tokens: 11, output_tokens: 22, cache_creation_tokens: 33, cached_tokens: 44)
  end

  describe "one error fixture per type" do
    {
      rate_limit: Anthropic::Errors::RateLimitError,
      overloaded: Anthropic::Errors::OverloadedError,
      timeout: Anthropic::Errors::APITimeoutError
    }.each do |kind, error_class|
      it "turns #{kind}, after the SDK's three attempts, into a model error carrying #{error_class.name.demodulize}" do
        result, fake = run_with(*Array.new(3) { error(kind) })

        expect(result).to have_attributes(outcome: :model_error, text: nil, error: an_instance_of(error_class))
        expect(fake.requests.size).to eq(3)
      end
    end

    it "answers after a failed attempt when the next one succeeds" do
      result, fake = run_with(error(:overloaded), reply("[pt] Pronto."))

      expect(result).to have_attributes(outcome: :replied, text: "Pronto.")
      expect(fake.requests.size).to eq(2)
    end
  end
end
