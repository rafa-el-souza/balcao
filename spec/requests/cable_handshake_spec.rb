require "rails_helper"
require "socket"
require "open3"
require "websocket/driver"
require_relative "../../config/required_environment"

# The cable's handshake through the whole app, as Puma hands it over: the
# middleware, the router, the gate at /cable (ADR-0015) and Action Cable, which
# takes the socket over when it accepts the handshake.
RSpec.describe "The cable's handshake at the Rack level" do
  let(:sockets) { [] }

  # A socket Action Cable took over is its to close, which it does once the
  # client goes (closing it under its event loop would stop the loop).
  after do
    sockets.each { |status, server, client| client.close; server.close unless status == -1 }
    taken = sockets.select { |status, *| status == -1 }.map { _2 }
    20.times { break if taken.all?(&:closed?); sleep 0.1 }
  end

  def handshake(origin: Rails.configuration.x.public_origin, source: "203.0.113.7", host: "example.org")
    server, client = UNIXSocket.pair
    env = Rack::MockRequest.env_for("http://#{host}/cable", {
      "HTTP_CONNECTION" => "Upgrade", "HTTP_UPGRADE" => "websocket",
      "HTTP_SEC_WEBSOCKET_VERSION" => "13", "HTTP_SEC_WEBSOCKET_KEY" => Base64.strict_encode64(SecureRandom.random_bytes(16)),
      "HTTP_SEC_WEBSOCKET_PROTOCOL" => "actioncable-v1-json, actioncable-unsupported",
      "HTTP_HOST" => host, "HTTP_ORIGIN" => origin, "REMOTE_ADDR" => source, "rack.hijack" => -> { server }
    }.compact)
    status = Rails.application.call(env).first
    sockets << [ status, server, client ]
    [ status, client ]
  end

  # A client's frame: masked, as RFC 6455 requires of a client.
  def masked(byte0, payload = "")
    mask = SecureRandom.random_bytes(4)
    [ byte0, 0x80 | payload.bytesize ].pack("CC") + mask + WebSocket::Mask.mask(payload.b, mask)
  end

  # Reads what the server writes until it closes the socket: true when it did
  # within the wait, false while it keeps the socket open.
  def closed_by_server?(client, wait = 2)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + wait
    loop do
      left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return false if left <= 0 || !client.wait_readable(left)
      return true if client.read_nonblock(65_536, exception: false).nil?
    end
  rescue Errno::ECONNRESET
    true
  end

  # What the server wrote on the socket it took over, up to the end of its head.
  def head(client)
    return "" unless client.wait_readable(2)

    answer = +""
    answer << client.readpartial(1) until answer.end_with?("\r\n\r\n")
    answer
  end

  describe "SR-03 only the public origin's page opens the cable" do
    it "takes the socket of the public origin's handshake over and answers 101" do
      status, client = handshake

      expect(status).to eq(-1)
      expect(head(client)).to start_with "HTTP/1.1 101 Switching Protocols"
    end

    [ [ "another site", "https://attacker.example" ], [ "an opaque origin", "null" ], [ "no origin", nil ],
      [ "the public name over another scheme", Rails.configuration.x.public_origin.sub(/\Ahttp/, "ws") ] ].each do |what, origin|
      it "answers 404 to #{what}, writing nothing on the socket" do
        status, client = handshake(origin:)

        expect(status).to eq 404
        expect(client.read_nonblock(1, exception: false)).to eq :wait_readable
      end
    end

    # Action Cable also accepts an Origin equal to the request's own Host
    # (allow_same_origin_as_host, on by default); production's host check
    # refuses every other Host first, and the cable no longer leans on it.
    it "answers 404 to a page whose origin is the request's own host, when that is not the public origin" do
      status, client = handshake(origin: "http://attacker.example", host: "attacker.example")

      expect(status).to eq 404
      expect(client.read_nonblock(1, exception: false)).to eq :wait_readable
    end
  end

  # The request specs run the test environment; production mounts the same
  # routes eagerly and has its own public origin and host check, so the gate
  # and the origin are read from a production boot too, as
  # spec/requests/response_headers_spec.rb does.
  it "SR-03 SR-04 answers the same from the production configuration" do
    probe = <<~RUBY
      call = lambda do |origin, version, host = "demo.example"|
        env = Rack::MockRequest.env_for("https://\#{host}/cable", "HTTP_HOST" => host, "HTTP_ORIGIN" => origin,
          "HTTP_CONNECTION" => "Upgrade", "HTTP_UPGRADE" => "websocket", "HTTP_SEC_WEBSOCKET_VERSION" => version,
          "HTTP_SEC_WEBSOCKET_KEY" => Base64.strict_encode64("the sample nonce"))
        Rails.application.call(env.compact).first
      end
      puts JSON.generate(
        hixie: call.("https://demo.example", nil),
        foreign: call.("https://attacker.example", "13"),
        own_host: call.("https://attacker.example", "13", "attacker.example"),
        mount: ActionCable.server.config.mount_path, same_origin_as_host: ActionCable.server.config.allow_same_origin_as_host
      )
    RUBY
    env = Balcao::RequiredEnvironment::NAMES.to_h { |name| [ name, "x" ] }.merge("MODEL_ADAPTER" => "real")
      .merge("APP_HOST" => "demo.example", "RAILS_ENV" => "production", "DATABASE_URL" => nil, "RAILS_LOG_LEVEL" => "fatal")

    out, err, status = Open3.capture3(env, "bin/rails", "runner", probe, chdir: Rails.root.to_s)

    expect(status).to be_success, err
    expect(JSON.parse(out.lines.last)).to eq("hixie" => 426, "foreign" => 404, "own_host" => 403,
                                             "mount" => nil, "same_origin_as_host" => false)
  end

  # Review finding C2 of pull request #23: nothing counted a ping, and each
  # was answered into a write buffer with no bound.
  it "SR-40 closes the socket at a ping from the client, and frees its place" do
    status, client = handshake(source: "198.51.100.40")
    expect(status).to eq(-1)
    head(client)

    client.write(masked(0x89))

    expect(closed_by_server?(client)).to be true
    server = sockets.last[1]
    20.times { break if server.closed?; sleep 0.05 }
    expect(server).to be_closed # what the gate prunes its count by
  end

  describe "SR-40 the gate counts the sockets Action Cable holds, until Action Cable closes them" do
    it "refuses a source's 21st socket and lets it in again once the source closes one" do
      opened = Array.new(20) { handshake }
      expect(opened.map(&:first).uniq).to eq [ -1 ]
      opened.each { |_, client| head(client) }

      expect(handshake.first).to eq 429

      opened.first.last.close
      admitted = 40.times.lazy.map { sleep 0.05; handshake.first }.find { _1 == -1 }

      expect(admitted).to eq(-1)
    end
  end
end
