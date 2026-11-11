require "rails_helper"

# Review finding C5 of pull request #10 (threat model SR-20): a query that
# waits on a lock, a migration's during a deploy or a stalled connection's,
# must not hold a turn past its sixty seconds, so every connection of the web
# and worker processes carries a statement timeout and a lock timeout.
RSpec.describe "SR-20 database connections give up on a stuck statement or lock wait" do
  def setting(name) = ApplicationRecord.connection.select_value("SHOW #{name}")

  it "sets a statement timeout and a lock timeout of a few seconds on every connection" do
    expect(setting("statement_timeout")).to eq "5s"
    expect(setting("lock_timeout")).to eq "2s"
  end

  it "applies them to every database of the production configuration" do
    configs = ActiveRecord::Base.configurations.configs_for(env_name: "production", include_hidden: true)

    expect(configs.map(&:name)).to contain_exactly("primary", "cache", "queue", "cable")
    configs.each do |config|
      expect(config.configuration_hash[:variables]).to include("statement_timeout" => "5s", "lock_timeout" => "2s")
    end
  end
end

# ConversationLock's wait is not a stuck statement: a job waits for the turn
# before its own, up to the turn's sixty seconds and its storage, so the lock
# is taken with neither timeout (design §6.3). Outside the transactional
# fixtures, since the holder and the waiter each need their own connection.
RSpec.describe "SR-20 design §6.3 ConversationLock waits for the turn ahead past the lock timeout" do
  self.use_transactional_tests = false

  it "takes the lock after the holder has held it longer than the lock timeout, and leaves the timeouts as they were" do
    conversation_id = SecureRandom.uuid
    held = Queue.new
    holder = Thread.new do
      ConversationLock.hold(conversation_id) do
        held << true
        sleep 2.5
      end
    end
    held.pop(timeout: 5)

    settings = ConversationLock.hold(conversation_id) do
      %w[statement_timeout lock_timeout].map { |name| ApplicationRecord.connection.select_value("SHOW #{name}") }
    end

    expect(settings).to eq %w[5s 2s]
  ensure
    holder&.join(5)
  end
end
