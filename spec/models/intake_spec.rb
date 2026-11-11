require "rails_helper"

RSpec.describe "FR-04 NFR-02 Intake puts an inbound message in the visitor's open conversation" do
  let(:visitor) { Visitor.identify!(channel: "web", identity_hash: SecureRandom.hex(32)) }

  def take_in(text, id: SecureRandom.uuid) = Intake.new(visitor).receive!(external_id: id, body: text)

  it "stores the message and its turn in the open conversation" do
    turn = take_in("oi")

    expect(turn.conversation).to eq Conversation.current_for!(visitor)
    expect(turn.inbound_message).to have_attributes(body: "oi", external_id: be_present)
    expect(turn).to be_received
  end

  # Review finding C5 of pull request #11: a reset that commits between the
  # intake's read of the open conversation and its write left the message in
  # the conversation the reset had closed, answered with what came before.
  it "stores a message in the conversation a reset opened when the reset closed the one it read" do
    first = take_in("oi").conversation
    opened = nil
    allow(Conversation).to(receive(:current_for!).and_wrap_original do |original, *args|
      read = original.call(*args)
      if opened.nil?
        # The reset commits here, after the read.
        read.class.where(id: read.id).update_all(closed_at: Time.current)
        opened = original.call(*args)
      end
      read
    end)

    turn = take_in("tem dipirona?")

    expect(opened).not_to eq first
    expect(turn.conversation).to eq opened
    expect(turn.inbound_message.conversation).to eq opened
  end

  it "holds the open conversation's row while it stores, so a reset's close waits for it" do
    conversation = Conversation.current_for!(visitor)
    locked = nil
    allow(Message).to(receive(:record_inbound!).and_wrap_original do |original, **args|
      locked = ApplicationRecord.connection.select_value(<<~SQL)
        SELECT count(*) FROM pg_locks l JOIN pg_class c ON c.oid = l.relation
        WHERE c.relname = 'conversations' AND l.mode = 'RowShareLock' AND l.granted
      SQL
      original.call(**args)
    end)

    take_in("oi")

    expect(locked).to be >= 1
    expect(conversation.reload.closed_at).to be_nil
  end

  it "returns the turn already stored for a message sent again, in the conversation it was stored in" do
    id = SecureRandom.uuid
    first = take_in("oi", id:)
    first.conversation.update!(closed_at: Time.current)

    expect(take_in("oi", id:)).to eq first
    expect(Conversation.count).to eq 1
  end

  describe "the 24-hour rule (FR-04, design §1.4)" do
    around { |example| travel_to(Time.zone.local(2026, 11, 11, 15, 0, 0)) { example.run } }

    it "counts from the last inbound message, not from the conversation's opening" do
      conversation = take_in("oi").conversation
      travel 23.hours
      take_in("ainda aí?")
      travel 23.hours

      expect(take_in("e agora?").conversation).to eq conversation
    end

    it "counts from the opening for a conversation with no inbound message yet" do
      conversation = Conversation.current_for!(visitor)
      travel 24.hours + 1.second

      expect(take_in("oi").conversation).not_to eq conversation
      expect(conversation.reload.closed_at).to eq Time.current
    end
  end
end
