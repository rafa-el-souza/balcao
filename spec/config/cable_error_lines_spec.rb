require "rails_helper"

# Threat model SR-30's sweep (M3-4): Action Cable's own lines.
#
# Its error lines write the error's message (review finding X1 of pull
# request #42): a worker's "There was an exception - Class(message)" and a
# command's "Could not execute command from (...) [Class - message]: ...". An
# error's message may quote a row the database refused, so only its class
# stays, as in Rails' own error lines (config/initializers/log_masking.rb).
#
# Its lines of a socket's start and end wrote the client's address, which
# the request's own line, written by Rails for /cable as for every request,
# keeps once, as the privacy page says the logs do (the round's triage at
# the MVP close).
RSpec.describe "SR-30 Action Cable's own lines" do
  let(:io) { StringIO.new }
  let(:logger) { Balcao::CableLogger.new(ActiveSupport::Logger.new(io)) }
  let(:quote) { "Failing row contains (11 98765-4321)" }

  it "keeps a worker's error by its class alone" do
    logger.error("There was an exception - ActiveRecord::NotNullViolation(PG::NotNullViolation: #{quote}\nDETAIL: more)")

    expect(io.string.chomp).to eq("There was an exception - ActiveRecord::NotNullViolation([FILTERED])")
  end

  it "keeps a refused command's error by its class alone, with the command and the frames" do
    logger.error(%(Could not execute command from ({"command" => "subscribe", "identifier" => "{\\"channel\\":\\"ConversationChannel\\"}"}) ) +
                 "[ActiveRecord::StatementInvalid - PG::Error: #{quote}]: /rails/app/channels/conversation_channel.rb:9:in 'subscribed' | " \
                 "/usr/local/bundle/gems/actioncable-8.1.4.1/lib/action_cable/channel/base.rb:200:in 'block in subscribe_to_channel'")

    expect(io.string).not_to include("98765")
    expect(io.string.chomp).to eq(%(Could not execute command from ({"command" => "subscribe", "identifier" => "{\\"channel\\":\\"ConversationChannel\\"}"}) ) +
                                  "[ActiveRecord::StatementInvalid - [FILTERED]]: /rails/app/channels/conversation_channel.rb:9:in 'subscribed' | " \
                                  "/usr/local/bundle/gems/actioncable-8.1.4.1/lib/action_cable/channel/base.rb:200:in 'block in subscribe_to_channel'")
  end

  # A client writes the command, so it may hold what the line's own parts
  # look like: the message is still kept out, and more of the line with it.
  it "keeps the error's message out whatever the client's command holds" do
    logger.error(%{Could not execute command from ({"identifier" => ") [X - y]: z"}) [RuntimeError - #{quote}]: /rails/app/x.rb:1:in 'y'})

    expect(io.string).not_to include("98765")
    expect(io.string).to include("/rails/app/x.rb:1:in 'y'")
  end

  # The verifier's reproduction of X1: a subscribe whose read raises an error
  # quoting a row, driven through the app's connection as Action Cable drives
  # a command.
  it "writes no word of the error's message when a subscribe breaks" do
    lines = []
    %i[info error].each { |level| allow(Rails.logger).to receive(level) { |line = nil, &block| lines << (line || block&.call).to_s } }
    allow(Conversation).to receive(:find_by_trace_token).and_raise(RuntimeError, quote)
    env = Rack::MockRequest.env_for("/cable", "REMOTE_ADDR" => "203.0.113.7")
    connection = ApplicationCable::Connection.new(ActionCable.server, env)

    connection.handle_channel_command({ "command" => "subscribe", "identifier" => { channel: "TraceChannel", token: "x" }.to_json })

    expect(lines.grep(/Could not execute command/).size).to eq(1)
    expect(lines.join("\n")).not_to include("98765")
  end

  it "names no address in its lines of a socket's start and end" do
    lines = []
    %i[info error].each { |level| allow(Rails.logger).to receive(level) { |line = nil, &block| lines << (line || block&.call).to_s } }
    env = Rack::MockRequest.env_for("/cable", "REMOTE_ADDR" => "203.0.113.7")

    ApplicationCable::Connection.new(ActionCable.server, env).process

    expect(lines.grep(/\A(Started|Finished) /).size).to eq(2)
    expect(lines.grep(/\AStarted GET "\/cable"/).sole).to match(/ at \d{4}-\d\d-\d\d /)
    expect(lines.join("\n")).not_to include("203.0.113.7")
  end
end
