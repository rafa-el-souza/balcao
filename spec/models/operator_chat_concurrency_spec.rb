require "rails_helper"

# Two updates carrying the same link's token, read at once by two jobs (two
# people's updates take two locks): one links, the other finds the token
# spent (threat model SR-35). It runs outside the transactional fixtures, each
# thread on a connection of its own, so it deletes its rows itself.
RSpec.describe "SR-35 a link's token links one chat, two at once" do
  self.use_transactional_tests = false

  after { OperatorChat.delete_all }

  it "spends the token once when two chats send it at the same time" do
    token = OperatorChat.link_url![/\?start=(.+)\z/, 1]
    gate = Queue.new

    threads = Array.new(2) do |index|
      Thread.new do
        gate.pop
        ActiveRecord::Base.connection_pool.with_connection do
          OperatorChat.link!(token, chat_id: 734_120_100 + index, language: "pt-BR")
        end
      end
    end
    2.times { gate << true }

    expect(threads.map(&:value)).to contain_exactly(true, false)
    expect(OperatorChat.sole.linked_at).to be_present
  end
end
