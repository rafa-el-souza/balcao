require "rails_helper"

# Review findings C3 and G1 of pull request #17: Action Cable writes the
# stream a page follows and the identifier it subscribes with in its own
# lines, which parameter filtering never reaches, and a trace's are its token,
# the whole credential of a conversation's trace page (threat model SR-11,
# SR-30).
RSpec.describe "SR-30 SR-11 the cable's log never names a trace's token" do
  let(:token) { SecureRandom.base58(24) }
  let(:io) { StringIO.new }
  let(:lines) do
    [ "TraceChannel is streaming from trace:#{token}",
      "TraceChannel stopped streaming from trace:#{token}",
      %(Unsubscribing from channel: {"channel":"TraceChannel","token":"#{token}"}),
      %(Could not execute command from ({"command" => "subscribe", "identifier" => "{\\"channel\\":\\"TraceChannel\\",\\"token\\":\\"#{token}\\"}"}) [ArgumentError - string contains null byte]) ]
  end

  it "writes [FILTERED] in the token's place in each of Action Cable's lines that carry it" do
    logger = Balcao::CableLogger.new(ActiveSupport::TaggedLogging.logger(io))
    proxy = ActionCable::Connection::TaggedLoggerProxy.new(logger, tags: [ "203.0.113.7" ])

    lines.each { |line| proxy.info(line) }
    proxy.error(lines.last)

    expect(io.string.lines.size).to eq(5)
    expect(io.string).not_to include(token)
    expect(io.string.scan("[FILTERED]").size).to eq(5)
    expect(io.string).to include("TraceChannel is streaming from trace:[FILTERED]", "[203.0.113.7]")
  end

  # Review finding C4 of pull request #23: Action Cable writes a message it
  # took off the socket after the socket closed through inspect, which escapes
  # the identifier's quotes twice (a trace page's unsubscribe, sent right
  # before its close).
  it "writes [FILTERED] in a message Action Cable dropped after the socket closed, its quotes escaped twice" do
    logger = Balcao::CableLogger.new(ActiveSupport::Logger.new(io))
    message = { command: "unsubscribe", identifier: { channel: "TraceChannel", token: }.to_json }.to_json

    logger.error("Ignoring message processed after the WebSocket was closed: #{message.inspect})")

    expect(io.string).not_to include(token)
    expect(io.string).to include("[FILTERED]")
  end

  it "leaves the conversations' streams and every other line as they are" do
    logger = Balcao::CableLogger.new(ActiveSupport::Logger.new(io))

    logger.info("ConversationChannel is streaming from conversation:01a1d1c7-7431-7f7b-86aa-3063482f4934")

    expect(io.string).to include("conversation:01a1d1c7-7431-7f7b-86aa-3063482f4934")
  end

  it "is the logger of the app's cable" do
    expect(ActionCable.server.config.logger).to be_a(Balcao::CableLogger)
  end
end
