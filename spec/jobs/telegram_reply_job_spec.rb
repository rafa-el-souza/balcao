require "rails_helper"

# FR-19: a Telegram visitor's stored replies, sent again once the time a
# failed send named has come; scheduled for that time, so nothing waits for
# it holding a worker's thread (review finding C3 of pull request #33). Its
# argument is the visitor's row, never the chat (threat model SR-10).
RSpec.describe "FR-19 SR-10 TelegramReplyJob, a reply tried again at its time" do
  include TelegramBotApi

  let(:visitor) { create(:visitor, channel: "telegram", telegram_chat_id: "7341200004", agreed_at: Time.current) }
  let(:conversation) { create(:conversation, visitor:) }
  let!(:sent) { stub_bot_api }

  it "sends the visitor's pending replies whose time has come" do
    inbound = create(:message, conversation:, external_id: "#{visitor.id}:1")
    reply = Message.record_outbound!(turn: Turn.for_inbound!(inbound), body: "Temos, sim.")
    reply.update_columns(send_attempts: 1, next_attempt_at: 1.minute.ago)

    TelegramReplyJob.perform_now(visitor.id)

    expect(sent.sole).to include("chat_id" => 7_341_200_004, "text" => "Temos, sim.")
    expect(reply.reload).to have_attributes(status: "sent", next_attempt_at: nil)
  end

  it "does nothing for a visitor a deletion took meanwhile" do
    expect { TelegramReplyJob.perform_now(SecureRandom.uuid) }.not_to raise_error

    expect(sent).to be_empty
  end
end
