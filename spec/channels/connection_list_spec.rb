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
  end
end
