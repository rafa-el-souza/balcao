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
    allow(connection).to receive(:select_value).with(/pg_advisory_unlock/, any_args).and_raise(ActiveRecord::ConnectionFailed)

    expect { ConversationLock.hold(conversation_id) { raise ArgumentError, "turn broke" } }.to raise_error(ArgumentError)
    expect(Rails.logger).to have_received(:error).with(/not released: ActiveRecord::ConnectionFailed/)
    connection.execute("SELECT pg_advisory_unlock_all()")
  end
end

# Review finding V1 of pull request #40 (threat model SR-30, SR-10): a lock's
# key names a person on Telegram by the hash of their identity, and it was
# written into the statement's text, which the database's own log keeps when
# the statement ends in an error (a reboot's fast shutdown ends a wait with
# one). It travels as a parameter, which that log leaves out.
RSpec.describe "SR-30 an advisory lock's key never in the statement's text" do
  it "sends the key as a parameter to take the lock and to release it" do
    key = "telegram:#{"ab" * 32}"
    statements = []
    recording = ->(*, payload) { statements << payload[:sql] }

    ActiveSupport::Notifications.subscribed(recording, "sql.active_record") { AdvisoryLock.hold(key) { nil } }

    expect(statements.grep(/pg_advisory_lock\(/).size).to eq(1)
    expect(statements.grep(/pg_advisory_unlock\(/).size).to eq(1)
    expect(statements.join("\n")).not_to include("ab" * 32)
  end

  # Review finding R2 of pull request #40 (the fix review): read as a value,
  # the lock's void result was cast, and Rails, which does not know the void
  # type, wrote a plain line to stderr on each connection's first lock,
  # outside the JSON log (NFR-05).
  it "takes the lock without a warning about its result's type" do
    ApplicationRecord.connection.send(:reload_type_map)

    expect { AdvisoryLock.hold("telegram:#{"cd" * 32}") { nil } }.not_to output(/unknown OID/).to_stderr
  end
end
