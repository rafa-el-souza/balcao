require "rails_helper"

RSpec.describe "NFR-02 SR-07 inbound message, keyed by the channel's message id" do
  let(:visitor) { create(:visitor, channel: "telegram") }
  let(:conversation) { create(:conversation, visitor:) }

  it "stores a new inbound message from the visitor, on the visitor's channel" do
    message = Message.record_inbound!(conversation:, external_id: "v1:7", body: "tem dipirona?")

    expect(message).to be_previously_new_record
    expect(message).to have_attributes(
      conversation:, channel: "telegram", external_id: "v1:7",
      direction: "inbound", author: "visitor", source: "text", body: "tem dipirona?", turn_id: nil
    )
  end

  # Review finding RN5 of pull request #7, design §10's standing trigger for
  # the next migration (M4-4): the rule that every inbound message has its
  # channel's id lived in record_inbound! alone; the database holds it too.
  it "is refused by the database without its channel's id, while a reply needs none" do
    row = { conversation_id: conversation.id, channel: "telegram", author: "visitor", source: "text", body: "oi" }

    expect { Message.insert!(row.merge(direction: "outbound", author: "bot")) }.not_to raise_error
    expect { Message.insert!(row.merge(direction: "inbound")) }.to raise_error(ActiveRecord::CheckViolation, /messages_inbound_has_id/)
  end

  it "keeps the same id on two channels apart" do
    web_conversation = create(:conversation, visitor: create(:visitor, channel: "web"))
    Message.record_inbound!(conversation: web_conversation, external_id: "id-1", body: "oi")

    expect(Message.record_inbound!(conversation:, external_id: "id-1", body: "oi")).to be_previously_new_record
  end

  # NFR-01 measures a turn from its message's receipt (M4-2): on Telegram the
  # update's arrival at the webhook, before the queue's wait and the job that
  # stored the message.
  describe "the message's receipt (NFR-01)" do
    it "is the update's arrival at the webhook for a message that came in one" do
      event = WebhookEvent.record!(update_id: 734_120_901, kind: "message", payload: "{}", received_at: 2.seconds.ago)
      message = Message.record_inbound!(conversation:, external_id: "v1:8", body: "oi", webhook_event: event)

      expect(message.received_at).to eq(event.received_at)
    end

    it "is when the message was stored for one that came in no update, as on the web" do
      message = Message.record_inbound!(conversation:, external_id: "v1:9", body: "oi")

      expect(message.received_at).to eq(message.created_at)
    end
  end

  it "does not key the replies, which carry no channel id" do
    2.times { create(:outbound_message, conversation:) }

    expect(conversation.messages.count).to eq(2)
  end

  # Review finding N2 of pull request #7: a web message carried no id, so a
  # request sent again after its response was lost stored a second message,
  # a second turn and a second model call.
  it "takes no inbound message without its channel's id" do
    expect { Message.record_inbound!(conversation:, external_id: nil, body: "oi") }.to raise_error(ArgumentError)
    expect { Message.record_inbound!(conversation:, external_id: " ", body: "oi") }.to raise_error(ArgumentError)
  end

  context "on the web, keyed by the id the client generates for each message" do
    let(:web_visitor) { create(:visitor, channel: "web") }
    let(:web_conversation) { create(:conversation, visitor: web_visitor) }
    let(:client_id) { "0b8f6f0e-4a8e-4c38-9f61-2b7f6d1f2c11" }

    it "stores a request sent twice once" do
      first = Message.record_inbound!(conversation: web_conversation, external_id: client_id, body: "tem dipirona?")
      again = Message.record_inbound!(conversation: web_conversation, external_id: client_id, body: "tem dipirona?")

      expect(again).to eq(first)
      expect(again).not_to be_previously_new_record
    end

    it "refuses an id that another visitor's message holds, rather than return that message (SR-05)" do
      Message.record_inbound!(conversation: web_conversation, external_id: client_id, body: "tem dipirona?")
      other = create(:conversation, visitor: create(:visitor, channel: "web"))

      expect { Message.record_inbound!(conversation: other, external_id: client_id, body: "oi") }
        .to raise_error(ActiveRecord::RecordNotUnique, /another visitor/)
      expect(other.messages).to be_empty
    end
  end

  it_behaves_like "an idempotency key", index: "index_messages_on_channel_and_external_id" do
    let(:existing) { create(:message, conversation:, external_id: "v1:8") }
    let(:duplicate) { build(:message, conversation:, external_id: "v1:8") }
    let(:call_again) do
      -> { Message.record_inbound!(conversation:, external_id: "v1:8", body: "tem dipirona?") }
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

  it "stores the reply in the conversation it is given, which a reset opened (FR-04)" do
    turn.conversation.update!(closed_at: Time.current)
    fresh = create(:conversation, visitor: turn.conversation.visitor)

    message = Message.record_outbound!(turn:, body: "Pronto.", conversation: fresh)

    expect(message).to have_attributes(conversation: fresh, turn:)
  end

  # Review finding V1 of pull request #18: PostgreSQL refuses a NUL in text,
  # so a reply carrying one could never be stored and its turn broke on every
  # attempt.
  it "stores a body without the NUL characters a model's reply may carry" do
    message = Message.record_outbound!(turn:, body: "Temos\u0000, sim.\u0000")

    expect(message.reload.body).to eq("Temos, sim.")
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

# Threat model SR-41: what a visitor sends is encrypted at rest, on every
# channel, and the model reads the plain text.
RSpec.describe "SR-41 a message's body is ciphertext in the database" do
  it "stores the body encrypted and gives it back, to the model's history too, as written" do
    message = create(:message, body: "Vocês têm dipirona?")
    turn = create(:turn, inbound_message: message)

    stored = Message.connection.select_value(Message.sanitize_sql([ "SELECT body FROM messages WHERE id = ?", message.id ]))
    expect(stored).not_to include("dipirona")
    expect(Message.find(message.id).body).to eq("Vocês têm dipirona?")
    expect(AgentRunner::History.messages(turn).sole[:content].last[:text]).to eq("Vocês têm dipirona?")
  end
end
