require "rails_helper"
require_relative "../../lib/logging/json_log_formatter"

# Threat model SR-30: an error's message never reaches the log, since it may
# quote what a visitor wrote (a database error quotes the row it refused),
# and the log outlives the deletion (FR-05) and the seven-day purge (FR-15).
# The app's own lines name an error by its class alone; Rails' lines of a
# failed job and of a failed request follow the same rule. NFR-05: in
# production each line is one JSON object, with the request's id and, in a
# turn, the conversation's.
RSpec.describe "SR-30 NFR-05 the log: an error by its class alone, one JSON object per line" do
  let(:io) { StringIO.new }
  let(:logger) { ActiveSupport::TaggedLogging.logger(io) }
  let(:quoted) { "PG::NotNullViolation: ERROR: null value. DETAIL: Failing row contains (meu telefone é 11 98765-4321)." }

  describe "Active Job's lines (design §10, the PR-12 note left them to PR-16)" do
    around do |example|
      previous = ActiveJob::Base.logger
      ActiveJob::Base.logger = logger
      example.run
    ensure
      ActiveJob::Base.logger = previous
    end

    before do
      error = quoted
      stub_const("QuotingJob", Class.new(ApplicationJob) do
        retry_on ActiveRecord::StatementInvalid, attempts: 2, wait: 0
        define_method(:perform) { raise ActiveRecord::StatementInvalid, error }
      end)
      stub_const("DiscardedJob", Class.new(ApplicationJob) do
        discard_on ActiveRecord::StatementInvalid
        define_method(:perform) { raise ActiveRecord::StatementInvalid, error }
      end)
    end

    # Both attempts on one job, as the queue would run them: the first is
    # retried, the second stops retrying and raises.
    def run_out(job)
      job.perform_now
      job.perform_now
    end

    it "names a failed, retried and stopped job's error by its class, never by its message" do
      expect { run_out(QuotingJob.new) }.to raise_error(ActiveRecord::StatementInvalid)

      expect(io.string).to include("Retrying QuotingJob", "Stopped retrying QuotingJob", "Error performing QuotingJob")
      expect(io.string.scan("ActiveRecord::StatementInvalid ([FILTERED])").size).to be >= 3
      expect(io.string).not_to include("98765")
    end

    it "names a discarded job's error by its class too" do
      DiscardedJob.perform_now

      expect(io.string).to include("Discarded DiscardedJob", "ActiveRecord::StatementInvalid ([FILTERED])")
      expect(io.string).not_to include("98765")
    end

    it "leaves the error itself as it was, for the job's own handling and the queue's record" do
      expect { run_out(QuotingJob.new) }.to raise_error(ActiveRecord::StatementInvalid, quoted)
    end
  end

  describe "a request's error line" do
    it "names the error and its causes by their classes, never by their messages" do
      app = lambda do |_env|
        raise ActiveRecord::StatementInvalid, quoted
      rescue ActiveRecord::StatementInvalid
        raise "could not store the message: meu telefone é 11 98765-4321"
      end
      env = Rack::MockRequest.env_for("/api/messages", method: "POST").merge(
        "action_dispatch.show_exceptions" => :all, "action_dispatch.logger" => logger,
        "action_dispatch.backtrace_cleaner" => Rails.backtrace_cleaner
      )

      expect { ActionDispatch::DebugExceptions.new(app).call(env) }.to raise_error(RuntimeError)

      expect(io.string).to include("RuntimeError ([FILTERED])", "Caused by: ActiveRecord::StatementInvalid ([FILTERED])")
      expect(io.string).not_to include("98765")
    end
  end

  describe "the production format (NFR-05)" do
    let(:json_logger) do
      ActiveSupport::TaggedLogging.new(ActiveSupport::Logger.new(io, formatter: Balcao::JsonLogFormatter.new))
    end

    def lines = io.string.lines.map { |line| JSON.parse(line) }

    it "writes one JSON object per line, with the time, the level and the message" do
      travel_to(Time.zone.local(2026, 11, 14, 3, 0, 1)) { json_logger.info("nightly reset: expired 1 reservations") }

      expect(lines).to eq([ { "time" => "2026-11-14T06:00:01.000Z", "level" => "INFO",
                              "message" => "nightly reset: expired 1 reservations" } ])
    end

    it "turns a tag of the form name=value into a field, and keeps the other tags in a list" do
      json_logger.tagged("request_id=3f1c", "ActiveJob", "conversation_id=01a1") { json_logger.warn("budget: paused") }

      expect(lines.sole).to include("request_id" => "3f1c", "conversation_id" => "01a1", "tags" => [ "ActiveJob" ],
                                    "level" => "WARN", "message" => "budget: paused")
    end

    it "keeps a message of several lines, a backtrace's, in one line of the log" do
      json_logger.tagged("request_id=3f1c") { json_logger.error("RuntimeError ([FILTERED]):\napp/x.rb:1\napp/y.rb:2") }

      expect(io.string.lines.size).to eq(1)
      expect(lines.sole["message"]).to eq("RuntimeError ([FILTERED]):\napp/x.rb:1\napp/y.rb:2")
    end

    it "writes bytes that are not UTF-8 without failing the caller" do
      json_logger.info("raw \xFF header".dup.force_encoding(Encoding::BINARY))

      expect(lines.sole["message"]).to eq("raw � header")
    end

    it "names an error logged as an object by its class alone (SR-30)" do
      json_logger.error(ActiveRecord::StatementInvalid.new(quoted))

      expect(lines.sole["message"]).to eq("ActiveRecord::StatementInvalid")
    end

    it "carries the conversation's id on every line a turn writes" do
      allow(Rails).to receive(:logger).and_return(json_logger)
      allow(AgentRunner).to receive(:default_client) { FakeModel.new([ ModelResponses.reply("[pt] Olá!") ]).client }
      allow(ActionCable.server).to receive(:broadcast).and_raise(RuntimeError, "cable down")
      conversation = create(:conversation)
      turn = Turn.for_inbound!(Message.record_inbound!(conversation:, external_id: SecureRandom.uuid, body: "oi"))

      ProcessTurnJob.perform_now(turn.id)

      line = lines.find { |entry| entry["message"] == "turn #{turn.id}: message not broadcast: RuntimeError" }
      expect(line).to include("conversation_id" => conversation.id, "level" => "ERROR")
      expect(lines.select { |entry| entry["message"].include?("not broadcast") }).to all(include("conversation_id" => conversation.id))
    end

    it "is the production logger, with the request's id as a field" do
      production = Rails.root.join("config/environments/production.rb").read

      expect(production).to include("Balcao::JsonLogFormatter.new")
      expect(production).to match(/config\.log_tags = \[ ->\(request\) \{ "request_id=\#\{request\.request_id\}" \} \]/)
    end
  end
end
