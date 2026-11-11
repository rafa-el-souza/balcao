require "rails_helper"

RSpec.describe ConversationChannel, "FR-18 SR-05 streams a conversation to the holder of the visitor cookie", type: :channel do
  around do |example|
    store = Rack::Attack.cache.store
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
    example.run
  ensure
    Rack::Attack.cache.store = store
  end

  let(:visitor) { Visitor.identify!(channel: "web", identity_hash: WebSession.identity_hash("a-token")) }
  let(:conversation) { Conversation.current_for!(visitor) }

  def connect_as(identity_hash, source: "203.0.113.7") = stub_connection(identity_hash:, source:)

  it "streams conversation:<id> for the visitor's own conversation" do
    connect_as(visitor.identity_hash)

    subscribe(conversation_id: conversation.id)

    expect(subscription).to be_confirmed
    expect(subscription).to have_stream_from("conversation:#{conversation.id}")
  end

  it "streams a conversation of the visitor a reset closed, whose stream carries the reset's reply (FR-04)" do
    closed = conversation.tap { |c| c.update!(closed_at: Time.current) }
    connect_as(visitor.identity_hash)

    subscribe(conversation_id: closed.id)

    expect(subscription).to have_stream_from("conversation:#{closed.id}")
  end

  it "rejects another visitor's conversation" do
    other = Visitor.identify!(channel: "web", identity_hash: SecureRandom.hex(32))
    connect_as(other.identity_hash)

    subscribe(conversation_id: conversation.id)

    expect(subscription).to be_rejected
  end

  it "rejects a connection without a visitor" do
    connect_as(nil)

    subscribe(conversation_id: conversation.id)

    expect(subscription).to be_rejected
  end

  [ nil, "", "not-a-uuid", 1, [ "x" ] ].each do |id|
    it "rejects the conversation id #{id.inspect}" do
      connect_as(visitor.identity_hash)

      subscribe(conversation_id: id)

      expect(subscription).to be_rejected
    end
  end

  it "rejects a WhatsApp visitor's conversation with the same identity hash" do
    whatsapp = Visitor.identify!(channel: "whatsapp", identity_hash: visitor.identity_hash)
    connect_as(visitor.identity_hash)

    subscribe(conversation_id: Conversation.current_for!(whatsapp).id)

    expect(subscription).to be_rejected
  end

  it "accepts no message from the page: subscribing is its only command" do
    expect(ConversationChannel.action_methods.to_a).to be_empty
  end

  it "SR-01 counts each subscription as a request of its source, and rejects past the per-IP limit" do
    connect_as(visitor.identity_hash)
    60.times { subscribe(conversation_id: conversation.id) }
    expect(subscription).to be_confirmed

    subscribe(conversation_id: conversation.id)

    expect(subscription).to be_rejected
  end
end
