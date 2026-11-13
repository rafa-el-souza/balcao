require "rails_helper"

# Every message a page sends on its socket is a command (subscribe,
# unsubscribe, message); a page sends one or two. Past 20 in a minute the
# connection is closed for good, before the command reaches Action Cable's
# message buffer or its worker pool, whose queue has no bound (ADR-0015).
RSpec.describe ApplicationCable::Connection, "SR-40 twenty commands a minute per connection" do
  # A connection as Action Cable builds one for a handshake it accepts, short
  # of taking the socket over (the test case's connection has no socket).
  let(:connection) do
    env = Rack::MockRequest.env_for("/cable", "HTTP_CONNECTION" => "Upgrade", "HTTP_UPGRADE" => "websocket",
                                              "HTTP_SEC_WEBSOCKET_VERSION" => "13", "HTTP_SEC_WEBSOCKET_KEY" => Base64.strict_encode64("the sample nonce"))
    described_class.new(ActionCable.server, env)
  end
  let(:buffer) { connection.send(:message_buffer) }
  let(:command) { { command: "subscribe", identifier: { channel: "TraceChannel", token: "x" }.to_json }.to_json }

  before do
    allow(buffer).to receive(:append)
    allow(connection).to receive(:close)
  end

  it "passes 20 commands within a minute on to Action Cable" do
    20.times { connection.on_message(command) }

    expect(buffer).to have_received(:append).with(command).exactly(20).times
    expect(connection).not_to have_received(:close)
  end

  it "closes the connection for good at the 21st, which goes nowhere" do
    21.times { connection.on_message(command) }

    expect(buffer).to have_received(:append).exactly(20).times
    expect(connection).to have_received(:close).with(reason: "limit", reconnect: false).once
  end

  it "counts a new minute from the first command after the last one ended" do
    travel_to Time.zone.local(2026, 11, 13, 21, 0, 0) do
      20.times { connection.on_message(command) }
      travel 59.seconds
      connection.on_message(command)
    end
    expect(connection).to have_received(:close).once

    other = described_class.new(ActionCable.server, connection.env)
    allow(other.send(:message_buffer)).to receive(:append)
    allow(other).to receive(:close)
    travel_to Time.zone.local(2026, 11, 13, 21, 0, 0) do
      20.times { other.on_message(command) }
      travel 60.seconds
      20.times { other.on_message(command) }
    end
    expect(other).not_to have_received(:close)
  end

  # The count overrides a method Action Cable marks :nodoc:. These two are the
  # path of every message the socket reads: if Rails changes either, this
  # breaks, and the count must be read again against the new code.
  describe "the methods of Action Cable the count relies on" do
    def source_of(owner, name)
      file, line = owner.instance_method(name).source_location
      lines = File.readlines(file).drop(line - 1)
      indent = lines.first[/\A */]
      lines.take(lines.index { _1 == "#{indent}end\n" } + 1).map { _1.delete_prefix(indent) }.join
    end

    it "reads each message of the socket through the connection's on_message" do
      expect(source_of(ActionCable::Connection::ClientSocket, :receive_message)).to eq <<~RUBY
        def receive_message(data)
          return unless @ready_state == OPEN

          @event_target.on_message(data)
        end
      RUBY
    end

    it "hands it to the message buffer there, and nowhere else" do
      expect(source_of(ActionCable::Connection::Base, :on_message)).to eq <<~RUBY
        def on_message(message) # :nodoc:
          message_buffer.append message
        end
      RUBY
      expect(described_class.instance_method(:on_message).super_method.owner).to eq ActionCable::Connection::Base
    end
  end
end
