require "rails_helper"

# FR-12: the trace page follows a conversation's trace by its token, read
# only; the token is the whole credential (SR-11).
RSpec.describe TraceChannel, "FR-12 SR-11 streams a trace to whoever holds its token", type: :channel do
  around do |example|
    store = Rack::Attack.cache.store
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
    example.run
  ensure
    Rack::Attack.cache.store = store
  end

  let(:conversation) { Conversation.current_for!(Visitor.identify!(channel: "web", identity_hash: SecureRandom.hex(32))) }

  before { stub_connection(identity_hash: nil, source: "203.0.113.7") }

  it "streams trace:<token> without a visitor cookie" do
    subscribe(token: conversation.trace_token)

    expect(subscription).to be_confirmed
    expect(subscription).to have_stream_from("trace:#{conversation.trace_token}")
  end

  # Review finding S4 of pull request #17: a token the database driver
  # refuses (a NUL) raised inside the subscription, which was then neither
  # confirmed nor rejected; a token of any shape the server never draws is a
  # miss without a lookup.
  [ "missing0000000000000000000", "", nil, 1, [ "x" ], "a\u0000b", "\xFF".b, "0OIl#{"a" * 20}" ].each do |token|
    it "rejects the token #{token.inspect}" do
      subscribe(token:)

      expect(subscription).to be_rejected
    end
  end

  it "accepts no message from the page: the stream is read only" do
    subscribe(token: conversation.trace_token)

    expect(TraceChannel.action_methods.to_a).to be_empty
  end

  it "SR-11 rate limits the lookups: past the per-IP limit even a valid token is rejected" do
    60.times { subscribe(token: "missing0000000000000000000") }

    subscribe(token: conversation.trace_token)

    expect(subscription).to be_rejected
  end
end
