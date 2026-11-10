require "rails_helper"

RSpec.describe "NFR-02 turn, one per inbound message" do
  let(:message) { create(:message) }

  it "creates the turn of an inbound message, received, in its conversation" do
    turn = Turn.for_inbound!(message)

    expect(turn).to be_previously_new_record
    expect(turn).to have_attributes(inbound_message: message, conversation: message.conversation, state: "received")
  end

  it "is not created for an outbound message" do
    outbound = create(:outbound_message)

    expect { Turn.for_inbound!(outbound) }.to raise_error(ActiveRecord::RecordInvalid)
  end

  it_behaves_like "an idempotency key", index: "index_turns_on_inbound_message_id" do
    let(:existing) { create(:turn, inbound_message: message) }
    let(:duplicate) { build(:turn, inbound_message: message) }
    let(:call_again) { -> { Turn.for_inbound!(message) } }
  end
end
