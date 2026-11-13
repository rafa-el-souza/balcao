require "rails_helper"

# Action Cable runs a socket's opening and its closing as two tasks of its
# worker pool, and the opening adds the connection to the server's list of
# connections at its very end. A socket closed right after its 101 may see
# its closing run first, find nothing to remove, and leave the connection in
# the list until the process ends: a slow leak a script can drive (measured:
# 59 of 1,000 sockets opened and closed at once; ADR-0015).
RSpec.describe ApplicationCable::Connection, "SR-40 a connection leaves Action Cable's list once its socket is gone" do
  include LibrarySource

  let(:connection) do
    env = Rack::MockRequest.env_for("/cable", "HTTP_CONNECTION" => "Upgrade", "HTTP_UPGRADE" => "websocket",
                                              "HTTP_SEC_WEBSOCKET_VERSION" => "13",
                                              "HTTP_SEC_WEBSOCKET_KEY" => Base64.strict_encode64("the sample nonce"))
    described_class.new(ActionCable.server, env)
  end
  let(:websocket) { connection.send(:websocket) }

  after { ActionCable.server.connections.delete(connection) }

  it "leaves the list when its socket closed while it opened, its closing having run first" do
    allow(websocket).to receive(:alive?).and_return(false)

    connection.send(:handle_close)
    connection.send(:handle_open)

    expect(ActionCable.server.connections).not_to include(connection)
  end

  it "stays in the list while its socket is open" do
    allow(websocket).to receive(:alive?).and_return(true)

    connection.send(:handle_open)

    expect(ActionCable.server.connections).to include(connection)
  end

  # Found by another session at the owner's word, on the list fix: the
  # closing that ran first found no internal channel to leave, and the opening
  # then subscribed one whose callback holds the connection, so it outlived
  # the list. The pub/sub here is Action Cable's inline adapter, run at once
  # (the test adapter posts its subscribe again, after the leave); in
  # production Solid Cable subscribes at once in the event loop's task.
  it "leaves its internal channel too, so a remote disconnect no longer reaches it" do
    server = ActionCable::Server::Base.new(config: ActionCable.server.config.dup.tap { _1.cable = { "adapter" => "inline" } })
    at_once = Object.new.tap { |loop| def loop.post = yield }
    allow(server).to receive(:event_loop).and_return(at_once)
    env = Rack::MockRequest.env_for("/cable", "HTTP_CONNECTION" => "Upgrade", "HTTP_UPGRADE" => "websocket",
                                              "HTTP_SEC_WEBSOCKET_VERSION" => "13", "REMOTE_ADDR" => "203.0.113.7",
                                              "HTTP_SEC_WEBSOCKET_KEY" => Base64.strict_encode64("the sample nonce"))
    gone = described_class.new(server, env)
    allow(gone.send(:websocket)).to receive(:alive?).and_return(false)
    allow(gone).to receive(:close)

    gone.send(:handle_close)
    gone.send(:handle_open)
    server.pubsub.broadcast("action_cable/203.0.113.7", { type: "disconnect" }.to_json)

    expect(gone).not_to have_received(:close)
  end

  it "relies on the opening adding it at its end, and the closing removing it first" do
    expect(source_of(ActionCable::Connection::Base, :handle_open)).to eq <<~RUBY
      def handle_open
        @protocol = websocket.protocol
        connect if respond_to?(:connect)
        subscribe_to_internal_channel
        send_welcome_message

        message_buffer.process!
        server.add_connection(self)
      rescue ActionCable::Connection::Authorization::UnauthorizedError
        close(reason: ActionCable::INTERNAL[:disconnect_reasons][:unauthorized], reconnect: false) if websocket.alive?
      end
    RUBY
    expect(source_of(ActionCable::Connection::Base, :handle_close)).to eq <<~RUBY
      def handle_close
        logger.info finished_request_message

        server.remove_connection(self)

        subscriptions.unsubscribe_from_all
        unsubscribe_from_internal_channel

        disconnect if respond_to?(:disconnect)
      end
    RUBY
    expect(source_of(ActionCable::Connection::InternalChannel, :subscribe_to_internal_channel)).to eq <<~RUBY
      def subscribe_to_internal_channel
        if connection_identifier.present?
          callback = -> (message) { process_internal_message decode(message) }
          @_internal_subscriptions ||= []
          @_internal_subscriptions << [ internal_channel, callback ]

          server.event_loop.post { pubsub.subscribe(internal_channel, callback) }
          logger.info "Registered connection (\#{connection_identifier})"
        end
      end
    RUBY
    expect(source_of(ActionCable::Connection::InternalChannel, :unsubscribe_from_internal_channel)).to eq <<~RUBY
      def unsubscribe_from_internal_channel
        if @_internal_subscriptions.present?
          @_internal_subscriptions.each { |channel, callback| server.event_loop.post { pubsub.unsubscribe(channel, callback) } }
        end
      end
    RUBY
  end
end
