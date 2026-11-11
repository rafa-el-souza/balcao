require "rails_helper"

RSpec.describe "design §6.3 ConversationLock, one turn at a time per conversation" do
  let(:conversation_id) { SecureRandom.uuid }

  def held_locks = ApplicationRecord.connection.select_value("SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND granted")

  it "holds an advisory lock while the block runs and releases it after" do
    inside = ConversationLock.hold(conversation_id) { held_locks }

    expect(inside).to eq(1)
    expect(held_locks).to eq(0)
  end

  it "releases the lock when the block raises, and the block's error is the one raised" do
    expect { ConversationLock.hold(conversation_id) { raise ArgumentError, "turn broke" } }.to raise_error(ArgumentError, "turn broke")
    expect(held_locks).to eq(0)
  end

  it "keeps the block's error when the release fails, and logs the release" do
    allow(Rails.logger).to receive(:error)
    connection = ApplicationRecord.connection
    allow(connection).to receive(:select_value).and_call_original
    allow(connection).to receive(:select_value).with(/pg_advisory_unlock/).and_raise(ActiveRecord::ConnectionFailed)

    expect { ConversationLock.hold(conversation_id) { raise ArgumentError, "turn broke" } }.to raise_error(ArgumentError)
    expect(Rails.logger).to have_received(:error).with(/not released: ActiveRecord::ConnectionFailed/)
    connection.execute("SELECT pg_advisory_unlock_all()")
  end
end
