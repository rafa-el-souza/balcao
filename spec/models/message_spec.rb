require "rails_helper"

RSpec.describe "NFR-02 SR-07 inbound message, keyed by the channel's message id" do
  let(:visitor) { create(:visitor, channel: "whatsapp") }
  let(:conversation) { create(:conversation, visitor:) }

  it "stores a new inbound message from the visitor, on the visitor's channel" do
    message = Message.record_inbound!(conversation:, external_id: "wamid.IN1", body: "tem dipirona?")

    expect(message).to be_previously_new_record
    expect(message).to have_attributes(
      conversation:, channel: "whatsapp", external_id: "wamid.IN1",
      direction: "inbound", author: "visitor", source: "text", body: "tem dipirona?", turn_id: nil
    )
  end

  it "keeps the same id on two channels apart" do
    web_conversation = create(:conversation, visitor: create(:visitor, channel: "web"))
    Message.record_inbound!(conversation: web_conversation, external_id: "id-1", body: "oi")

    expect(Message.record_inbound!(conversation:, external_id: "id-1", body: "oi")).to be_previously_new_record
  end

  it "does not key messages that carry no channel id" do
    2.times { create(:message, conversation:, external_id: nil) }

    expect(conversation.messages.count).to eq(2)
  end

  it_behaves_like "an idempotency key", index: "index_messages_on_channel_and_external_id" do
    let(:existing) { create(:message, conversation:, external_id: "wamid.REDELIVERED") }
    let(:duplicate) { build(:message, conversation:, external_id: "wamid.REDELIVERED") }
    let(:call_again) do
      -> { Message.record_inbound!(conversation:, external_id: "wamid.REDELIVERED", body: "tem dipirona?") }
    end
  end
end

RSpec.describe "NFR-02 outbound message, one per turn" do
  let(:turn) { create(:turn) }

  it "stores the reply of a turn as a pending outbound message of its conversation" do
    message = Message.record_outbound!(turn:, body: "Temos, sim.")

    expect(message).to be_previously_new_record
    expect(message).to have_attributes(
      conversation: turn.conversation, turn:, direction: "outbound", author: "bot",
      source: "text", body: "Temos, sim.", status: "pending"
    )
  end

  it "refuses a turn on an inbound message (a turn is keyed on the turn table)" do
    message = build(:message, conversation: turn.conversation, turn:)

    expect { Message.transaction(requires_new: true) { message.save!(validate: false) } }
      .to raise_error(ActiveRecord::StatementInvalid, /messages_turn_only_on_outbound/)
  end

  it_behaves_like "an idempotency key", index: "index_messages_one_outbound_per_turn" do
    let(:existing) { create(:outbound_message, turn:) }
    let(:duplicate) { build(:outbound_message, turn:) }
    let(:call_again) { -> { Message.record_outbound!(turn:, body: "Temos, sim.") } }
  end
end
