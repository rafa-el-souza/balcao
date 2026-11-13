require "rails_helper"

# Action Cable writes a refused command whole into its line ("Could not
# execute command from (...)"), up to the 16 KiB a message may carry: 1,000
# such commands wrote 15.7 MB of log (ADR-0015). Each of its lines is cut at
# 2 KB, after the trace tokens are filtered from the whole line (SR-30).
RSpec.describe "SR-40 the cable writes at most 2 KB a line" do
  let(:io) { StringIO.new }
  let(:logger) { Balcao::CableLogger.new(ActiveSupport::Logger.new(io)) }

  it "cuts a line past 2 KB, marking the cut" do
    logger.error("Could not execute command from (#{"x" * 16_000})")

    expect(io.string.chomp.bytesize).to be <= 2048
    expect(io.string.chomp).to start_with("Could not execute command from (xxx").and end_with("...")
  end

  # Puma hands the headers over as raw bytes, and Action Cable writes a
  # refused Origin into its line as it came.
  it "cuts a long line of raw bytes, as a header's are, without raising" do
    logger.error("Request origin not allowed: #{"\xFF".b * 3000}")

    expect(io.string.chomp.bytesize).to be <= 2048
    expect(io.string.chomp).to start_with("Request origin not allowed: ").and end_with("...")
  end

  it "cuts between characters, never inside one" do
    logger.info("ç" * 2000)

    expect(io.string.chomp).to be_valid_encoding
    expect(io.string.chomp.bytesize).to be <= 2048
  end

  it "filters a trace's token before the cut, wherever it is in the line" do
    token = SecureRandom.base58(24)

    logger.info(%(#{"y" * 2030} {"channel":"TraceChannel","token":"#{token}"}))
    logger.info("TraceChannel is streaming from trace:#{token}")

    expect(io.string).not_to include(token[0, 6])
    expect(io.string).to include("trace:[FILTERED]")
  end

  # Review finding N4 of pull request #23: Action Cable logs an exception's
  # backtrace as one message, a line per frame, which the cut took whole.
  it "cuts each line of a message, so a backtrace keeps every frame" do
    backtrace = Array.new(60) { "/usr/local/bundle/gems/actioncable-8.1.4.1/lib/action_cable/server/worker.rb:#{_1}:in 'invoke'" }

    logger.error(backtrace.join("\n"))
    logger.error("#{"y" * 3000}\nand a short one")

    expect(io.string.lines.size).to eq 62
    expect(io.string.lines.map(&:bytesize).max).to be <= 2049
    expect(io.string.lines.last.chomp).to eq "and a short one"
  end

  it "leaves a line within 2 KB as it is, and the block form too" do
    logger.info("Registered connection (203.0.113.7)")
    logger.info { "Finished \"/cable\" [WebSocket]" }

    expect(io.string.lines.map(&:chomp)).to eq [ "Registered connection (203.0.113.7)", "Finished \"/cable\" [WebSocket]" ]
  end
end
