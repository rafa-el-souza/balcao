# Design NFR-02: every idempotency key is a unique index in the database, and
# the application meets a duplicate by rescuing the database's RecordNotUnique
# and returning the row that already holds the key. The specs are
# deterministic: the duplicate is in place before the call, so the rescue path
# runs on every run rather than only when two writers happen to race.
#
# Keys written once (an event, a message, a turn, a reservation) insert first
# and look up only after the index refuses the row. Keys read on every request
# (a visitor, the open conversation, the month's budget) look up first; their
# race is the read missing a row that another writer commits just before the
# insert, which a spec reproduces by stubbing that read to miss.
module IdempotencyKeyHelpers
  # Runs the block and returns its result with the classes of every exception
  # raised inside it on this thread, the rescued ones included.
  def with_raised_exceptions
    raised = []
    trace = TracePoint.new(:raise) { |point| raised << point.raised_exception.class }
    result = trace.enable(target_thread: Thread.current) { yield }
    [ result, raised ]
  end
end

RSpec.configure do |config|
  config.include IdempotencyKeyHelpers
end

# The including group defines:
#   existing   - the row that holds the key, already saved
#   duplicate  - an unsaved row carrying the same key
#   call_again - a lambda that runs the application's path with the same key
RSpec.shared_examples "an idempotency key" do |index:|
  it "is the unique index #{index}: the database refuses a second row with the key" do
    existing
    expect { duplicate.class.transaction(requires_new: true) { duplicate.save!(validate: false) } }
      .to raise_error(ActiveRecord::RecordNotUnique, /"#{index}"/)
  end

  it "rescues the RecordNotUnique of the duplicate and returns the row that holds the key" do
    existing
    count = existing.class.count

    result, raised = with_raised_exceptions { call_again.call }

    expect(raised).to include(ActiveRecord::RecordNotUnique)
    expect(result).to eq(existing)
    expect(result).not_to be_previously_new_record
    expect(existing.class.count).to eq(count)
  end
end
