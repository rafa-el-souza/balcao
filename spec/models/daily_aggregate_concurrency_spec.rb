require "rails_helper"

# NFR-02's key on the day's counts, under concurrent writers: every count
# lands on the one row. It runs outside the transactional fixtures, each
# thread on a connection of its own, so it deletes its rows itself.
RSpec.describe "NFR-02 FR-17 the day's counts, concurrent writers" do
  self.use_transactional_tests = false

  after { DailyAggregate.delete_all }

  it "adds every count of concurrent writers to the one row" do
    gate = Queue.new
    writers = Array.new(4) do
      Thread.new do
        gate.pop
        ActiveRecord::Base.connection_pool.with_connection { 5.times { DailyAggregate.add!(kind: "canary", key: "passed") } }
      end
    end
    4.times { gate << true }
    writers.each(&:join)

    expect(DailyAggregate.where(kind: "canary", key: "passed").pluck(:count)).to eq([ 20 ])
  end
end
