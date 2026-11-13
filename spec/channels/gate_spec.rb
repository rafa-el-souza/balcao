require "rails_helper"
require "socket"

# The cable's front door at /cable (ADR-0015): it answers, before Action Cable
# takes the socket over, a handshake that is not RFC 6455's, and a socket past
# the caps.
RSpec.describe ApplicationCable::Gate, type: :channel do
  let(:pairs) { [] }

  after { pairs.flatten.each { |io| io.close unless io.closed? } }

  # A WebSocket handshake as a browser sends it, from a source address, with a
  # socket for the server to take over.
  def handshake(source: "203.0.113.7", **headers)
    server, client = UNIXSocket.pair
    pairs << [ server, client ]
    Rack::MockRequest.env_for("/cable", {
      "HTTP_CONNECTION" => "Upgrade", "HTTP_UPGRADE" => "websocket",
      "HTTP_SEC_WEBSOCKET_VERSION" => "13", "HTTP_SEC_WEBSOCKET_KEY" => Base64.strict_encode64("the sample nonce"),
      "REMOTE_ADDR" => source, "rack.hijack" => -> { server }
    }.merge(headers).compact)
  end

  # The cable as Action Cable answers a handshake it accepts: it takes the
  # socket over (the server ignores the answer).
  let(:taken) { [] }
  let(:cable) do
    lambda do |env|
      taken << env["rack.hijack"].call
      [ -1, {}, [] ]
    end
  end

  describe "SR-04 a handshake that is not RFC 6455's is refused before the upgrade" do
    subject(:gate) { described_class.new(cable) }

    it "answers 426 with the version it speaks to a handshake of another version, or of none (hixie-75 and -76)" do
      [ nil, "8", "12", "13, 8", "" ].each do |version|
        status, headers, = gate.call(handshake("HTTP_SEC_WEBSOCKET_VERSION" => version))

        expect(status).to eq(426), version.inspect
        expect(headers["sec-websocket-version"]).to eq "13"
      end
      expect(gate.call(handshake("HTTP_SEC_WEBSOCKET_VERSION" => nil, "HTTP_SEC_WEBSOCKET_KEY" => nil,
                                 "HTTP_SEC_WEBSOCKET_KEY1" => "4 @1  46546xW%0l 1 5")).first).to eq 426
      expect(taken).to be_empty
    end

    it "answers 400 to a version 13 handshake without a key, or with an empty one" do
      [ nil, "", " " ].each do |key|
        expect(gate.call(handshake("HTTP_SEC_WEBSOCKET_KEY" => key)).first).to eq(400), key.inspect
      end
      expect(taken).to be_empty
    end

    it "sends a version 13 handshake with a key to the cable, which checks the rest (the key's 16 bytes are not checked)" do
      expect(gate.call(handshake("HTTP_SEC_WEBSOCKET_KEY" => "short")).first).to eq(-1)
      expect(taken.size).to eq 1
    end

    it "leaves a request that asks for no upgrade to the cable, which answers it itself" do
      plain = Rack::MockRequest.env_for("/cable", "REMOTE_ADDR" => "203.0.113.7")
      inner = ->(_env) { [ 404, {}, [ "Page not found" ] ] }

      expect(described_class.new(inner).call(plain).first).to eq 404
    end

    it "writes nothing to the socket: the answer goes through the server, which owns it still" do
      status, headers, body = gate.call(handshake("HTTP_SEC_WEBSOCKET_VERSION" => nil))

      expect([ status, headers["content-type"], body.join ]).to eq [ 426, "application/json; charset=utf-8", %({"error":"version"}) ]
      expect(pairs.last.last.read_nonblock(1, exception: false)).to eq :wait_readable
    end
  end

  describe "SR-40 the sockets the cable holds are capped per process and per source" do
    it "takes 20 sockets of one source and answers the 21st with 429 before the cable sees it; another source still gets in" do
      gate = described_class.new(cable)

      statuses = Array.new(21) { gate.call(handshake(source: "203.0.113.7")).first }

      expect(statuses.tally).to eq(-1 => 20, 429 => 1)
      expect(taken.size).to eq 20
      expect(gate.call(handshake(source: "198.51.100.9")).first).to eq(-1)
    end

    it "counts a source's socket until the cable closes it" do
      gate = described_class.new(cable)
      20.times { gate.call(handshake) }

      taken.first.close

      expect(gate.call(handshake).first).to eq(-1)
      expect(gate.call(handshake).first).to eq 429
    end

    it "answers 503 past the process's sockets, whatever the source" do
      gate = described_class.new(cable, max: 3)

      statuses = [ "198.51.100.1", "198.51.100.2", "198.51.100.3", "198.51.100.4" ].map { gate.call(handshake(source: _1)).first }

      expect(statuses).to eq [ -1, -1, -1, 503 ]
    end

    # Review finding C3 of pull request #23: the caps were checked in one lock
    # and the socket recorded in another, with the takeover between them.
    it "holds a place from the check, so two handshakes at once never share the last one" do
      inside = Queue.new
      release = Queue.new
      first = true
      slow = lambda do |env|
        taken << env["rack.hijack"].call
        if first
          first = false
          inside << true
          release.pop
        end
        [ -1, {}, [] ]
      end
      gate = described_class.new(slow, per_source: 1)

      waiting = Thread.new { gate.call(handshake).first }
      inside.pop
      second = gate.call(handshake).first
      release << true

      expect([ waiting.value, second ]).to eq [ -1, 429 ]
      expect(taken.size).to eq 1
      expect(gate.call(handshake).first).to eq 429
    end

    it "counts only the sockets the cable took over: a handshake it refused, for its origin say, holds none" do
      refuses = ->(_env) { [ 404, {}, [ "Page not found" ] ] }
      gate = described_class.new(refuses)

      expect(Array.new(25) { gate.call(handshake).first }.uniq).to eq [ 404 ]
    end

    it "counts an IPv6 source by its /64, as the edge's limits do (SR-36)" do
      gate = described_class.new(cable, per_source: 2)

      statuses = [ "2001:db8::1", "2001:db8::2", "2001:db8::ffff" ].map { gate.call(handshake(source: _1)).first }

      expect(statuses).to eq [ -1, -1, 429 ]
    end

    it "refuses with a plain answer, so the page's cable client tries again later by itself (no reconnect: false)" do
      gate = described_class.new(cable, per_source: 1)
      gate.call(handshake)

      status, headers, body = gate.call(handshake)

      expect([ status, headers["content-type"], headers["cache-control"], body.join ])
        .to eq [ 429, "application/json; charset=utf-8", "no-store", %({"error":"limit"}) ]
    end
  end
end
