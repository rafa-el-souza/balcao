require "rails_helper"

# Design §8, ADR-0011 (M3-6b): a rehearsal host runs MODEL_ADAPTER=fake, the
# recorded model (RecordedModel), on the committed recordings of the evals.
# These turns run as the host runs them: the visitors' turn job, the tools
# against the host's own catalogue, FR-20's check and the stored reply, with
# no key; FR-17's canary passes there, and so does the smoke's opener.
RSpec.describe "Design §8 ADR-0011 FR-17 FR-21 turns on a rehearsal host's recorded model" do
  include ActiveJob::TestHelper

  let(:model) { RecordedModel.load }

  before do
    allow(AgentRunner).to receive(:default_client) { model.client }
    allow(Guardrail).to receive(:default_client) { model.client }
    CatalogueSeed.seed!
  end

  def turn_for(text)
    conversation = create(:conversation, visitor: create(:visitor))
    message = Message.record_inbound!(conversation:, external_id: SecureRandom.uuid, body: text)
    Turn.for_inbound!(message).tap { |turn| ProcessTurnJob.perform_now(turn.id) }.reload
  end

  def reply(turn) = Message.find_by(turn_id: turn.id).body_without_notice

  # The canary asks on the economy model, the recording was made on the
  # normal one: the recorded model answers the message, whatever the route.
  it "passes FR-17's canary, its question answered by the recording and checked by FR-20's recorded check" do
    saved = Rails.configuration.x.budget_cap_usd
    Rails.configuration.x.budget_cap_usd = BigDecimal("10")

    result = Canary.new(heartbeat: Heartbeat.new(nil, name: "canary")).run

    expect(result).to have_attributes(passed: true, mode: "economy")
    expect(DailyAggregate.find_by(kind: "canary", key: "passed")&.count).to eq 1
  ensure
    Rails.configuration.x.budget_cap_usd = saved
  end

  # The rehearsal flow's smoke sends the stock chip (docs/runbook.md); every
  # chip of the landing is a recorded case's message (spec/evals/seed_spec.rb).
  it "answers every chip of the landing through a visitor's turn, the stock chip with a price from the host's catalogue" do
    replies = Openers.current.keys.to_h { |key| [ key, turn_for(Openers.current.fetch(key).text) ] }

    expect(replies.values.map(&:state)).to all(eq "replied")
    expect(replies.values.map(&:reply_kind)).to all(be_in(%w[model decline call_now]))
    expect(reply(replies.fetch("stock_pt"))).to include("R$")
    expect(reply(replies.fetch("delivery_es"))).to include("Santa Tereza")
  end

  it "ends a message no recording answers with the fixed apology, as a model error" do
    turn = turn_for("vocês vendem protetor solar fator 50?")
    root = TraceEvent.where(turn_id: turn.id, name: "balcao.turn").sole.span_attributes

    expect(turn).to have_attributes(state: "failed", reply_kind: "fallback")
    expect(reply(turn)).to eq FixedReply.fallback(turn.conversation.language)
    expect(root).to include("balcao.turn.outcome" => "model_error", "error.type" => "Anthropic::Errors::NotFoundError")
  end
end
