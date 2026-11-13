require "rails_helper"
require "websocket/driver"

# Action Cable builds its WebSocket driver with no size limit, so
# websocket-driver's own applies: 64 MiB a message, buffered whole before
# anything reads it. The app gives the driver 16 KiB (ADR-0015, option A); a
# page's command is about a hundred bytes.
RSpec.describe "SR-04 a cable message over 16 KiB closes the socket" do
  # The socket as the driver sees it: the handshake's env, and what it writes.
  let(:socket) do
    Struct.new(:env, :written) { def write(data) = written << data }
          .new(Rack::MockRequest.env_for("/cable", "HTTP_CONNECTION" => "Upgrade", "HTTP_UPGRADE" => "websocket",
                                                   "HTTP_SEC_WEBSOCKET_VERSION" => "13",
                                                   "HTTP_SEC_WEBSOCKET_KEY" => Base64.strict_encode64("the sample nonce")), +"".b)
  end

  # A client's text frame: masked, as RFC 6455 requires of a client.
  def frame(payload)
    mask = SecureRandom.random_bytes(4)
    header(payload.bytesize, mask) + WebSocket::Mask.mask(payload.b, mask)
  end

  def header(size, mask = SecureRandom.random_bytes(4))
    length = if size < 126 then [ 0x80 | size ].pack("C")
    elsif size < 65_536 then [ 0x80 | 126, size ].pack("Cn")
    else [ 0x80 | 127, size ].pack("CQ>")
    end
    [ 0x81 ].pack("C") + length + mask
  end

  # Opens the driver Action Cable would build, sends each payload as one frame
  # and answers what came of them.
  def drive(*payloads)
    driver = WebSocket::Driver.rack(socket, protocols: ActionCable::INTERNAL[:protocols])
    events = []
    driver.on(:message) { events << [ :message, _1.data.bytesize ] }
    driver.on(:close) { events << [ :close, _1.code ] }
    driver.start
    payloads.each { driver.parse(frame(_1)) }
    events
  end

  it "passes a message of 16,384 bytes" do
    expect(drive("a" * 16_384)).to eq [ [ :message, 16_384 ] ]
  end

  it "closes with 1009 at 16,385 bytes, and reads nothing after" do
    expect(drive("a" * 16_385, "a")).to eq [ [ :close, 1009 ] ]
  end

  it "closes from the frame's header, before its payload arrives" do
    driver = WebSocket::Driver.rack(socket, protocols: ActionCable::INTERNAL[:protocols])
    closes = []
    driver.on(:close) { closes << _1.code }
    driver.start
    driver.parse(header(32 * 1024 * 1024))

    expect(closes).to eq [ 1009 ]
  end

  # Review finding C2 of pull request #23: websocket-driver answers a ping at
  # once, into Action Cable's write buffer, which has no bound when the client
  # does not read, and neither frame reaches the count of commands. A browser
  # sends neither: the cable's pings are messages of its own.
  [ [ "ping", 0x89 ], [ "pong", 0x8A ] ].each do |name, byte0|
    it "SR-40 fails the connection at a #{name} from the client, with 1008, and reads nothing after" do
      driver = WebSocket::Driver.rack(socket, protocols: ActionCable::INTERNAL[:protocols])
      events = []
      driver.on(:message) { events << :message }
      driver.on(:close) { events << [ :close, _1.code ] }
      driver.start
      mask = SecureRandom.random_bytes(4)

      driver.parse([ byte0, 0x80 ].pack("CC") + mask + frame("a command after it"))

      expect(events).to eq [ [ :close, 1008 ] ]
      expect(driver.state).to eq :closed
    end
  end

  it "keeps a smaller limit a caller asks for" do
    driver = WebSocket::Driver.rack(socket, max_length: 1024)
    closes = []
    driver.on(:close) { closes << _1.code }
    driver.start
    driver.parse(frame("a" * 1025))

    expect(closes).to eq [ 1009 ]
  end
end
