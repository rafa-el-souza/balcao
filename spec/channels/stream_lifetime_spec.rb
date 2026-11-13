require "rails_helper"

# Review finding S1 of pull request #23 (another session reported it; the
# verifier traced two routes). stream_from posts its pub/sub subscribe to the
# event loop's pool of threads, with no order against the closing, which
# unsubscribes at once, and a subscribe command and the closing run on
# different threads of the worker pool. A channel subscribed and closed at
# once could keep its stream for good, holding the channel and its
# connection. Here the event loop's tasks are held and run in the order each
# route takes, on Action Cable's inline pub/sub, as Solid Cable subscribes.
RSpec.describe ApplicationCable::Channel, "SR-40 a stream lives no longer than its channel and its socket", type: :channel do
  include LibrarySource

  let(:posted) { [] }
  let(:server) do
    ActionCable::Server::Base.new(config: ActionCable.server.config.dup.tap { _1.cable = { "adapter" => "inline" } }).tap do |server|
      held = Object.new
      queue = posted
      held.define_singleton_method(:post) { |task = nil, &block| queue << (task || block) }
      allow(server).to receive(:event_loop).and_return(held)
    end
  end
  let(:connection) do
    env = Rack::MockRequest.env_for("/cable", "HTTP_CONNECTION" => "Upgrade", "HTTP_UPGRADE" => "websocket",
                                              "HTTP_SEC_WEBSOCKET_VERSION" => "13", "REMOTE_ADDR" => "203.0.113.7",
                                              "HTTP_SEC_WEBSOCKET_KEY" => Base64.strict_encode64("the sample nonce"))
    ApplicationCable::Connection.new(server, env)
  end
  let(:websocket) { connection.send(:websocket) }
  let(:conversation) { Conversation.current_for!(Visitor.identify!(channel: "web", identity_hash: SecureRandom.hex(32))) }
  let(:subscribe) { { "command" => "subscribe", "identifier" => { channel: "TraceChannel", token: conversation.trace_token }.to_json } }
  let(:streaming) { server.pubsub.send(:subscriber_map).instance_variable_get(:@subscribers) }

  def run_posted
    posted.shift.call until posted.empty?
  end

  before do
    allow(websocket).to receive(:alive?).and_return(true)
    connection.send(:handle_open)
    run_posted
  end

  it "keeps the stream of a channel whose socket is open" do
    connection.handle_channel_command(subscribe)
    run_posted

    expect(streaming).to have_key("trace:#{conversation.trace_token}")
  end

  it "lets the stream go when the closing ran before the stream's subscribe was done" do
    connection.handle_channel_command(subscribe)
    allow(websocket).to receive(:alive?).and_return(false)
    connection.send(:handle_close)
    run_posted

    expect(streaming).not_to have_key("trace:#{conversation.trace_token}")
  end

  it "lets the stream go when the closing ran before the subscription was there to find" do
    allow(websocket).to receive(:alive?).and_return(false)
    connection.send(:handle_close)
    connection.handle_channel_command(subscribe) # a dispatch that found the socket open just before
    run_posted

    expect(streaming).not_to have_key("trace:#{conversation.trace_token}")
  end

  # The fix waits for each stream's subscribe to be done, and Action Cable
  # tells it so by the confirmation's callback, which the pub/sub calls inside
  # its lock (a Mutex: the stream is let go in a task of its own).
  it "relies on stream_from confirming from the pub/sub's callback, called once the subscriber is in" do
    expect(source_of(ActionCable::Channel::Streams, :stream_from)).to include(<<~RUBY.indent(2))
      connection.server.event_loop.post do
        pubsub.subscribe(broadcasting, handler, lambda do
          ensure_confirmation_sent
    RUBY
    expect(source_of(ActionCable::SubscriptionAdapter::SubscriberMap, :add_subscriber)).to eq <<~RUBY
      def add_subscriber(channel, subscriber, on_success)
        @sync.synchronize do
          new_channel = !@subscribers.key?(channel)

          @subscribers[channel] << subscriber

          if new_channel
            add_channel channel, on_success
          elsif on_success
            on_success.call
          end
        end
      end
    RUBY
  end
end
