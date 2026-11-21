require "rails_helper"
require "fugit"

# FR-17: every ten minutes the canary asks the attendant a visitor's question
# on a reserved conversation of a fixed system visitor, through a visitor's
# turn (the budget's gate, AgentRunner, FR-20's check, the stored reply) with
# no transport, always on the economy model (ADR-0003); it passes when the
# reply comes within 20 seconds and holds the marker its question elicits, or,
# when the demo is paused, when the reply is a pause's fixed text ("pipeline
# alive", not "model answered"). Each run counts as passed or failed on the
# day (FR-13's pipeline uptime, NFR-04) and tells the external monitor; it
# keeps only the conversation and the count, and its calls count toward the
# month's spend.
RSpec.describe "FR-17 NFR-04 the canary" do
  include ModelResponses
  include ActiveJob::TestHelper

  let(:monitor) { "https://monitor.example/api/v1/heartbeat/canary-token-of-the-specs" }
  let(:answer) { "[pt] Olá! A Farmácia Vida Longa fica na Rua dos Boticários, 120 — Floresta, em Belo Horizonte." }
  let(:responses) { [ reply(answer, model: "claude-haiku-5-5") ] }
  let(:fake) { FakeModel.new(responses) }
  let!(:beat) { stub_request(:post, monitor).to_return(status: 200) }
  let!(:failure) { stub_request(:post, "#{monitor}/fail").to_return(status: 200) }

  around do |example|
    saved = [ Rails.configuration.x.budget_cap_usd, Rails.configuration.x.monitor_url ]
    Rails.configuration.x.budget_cap_usd = BigDecimal("10")
    Rails.configuration.x.monitor_url = monitor
    example.run
  ensure
    Rails.configuration.x.budget_cap_usd, Rails.configuration.x.monitor_url = saved
  end

  before do
    allow(AgentRunner).to receive(:default_client) { fake.client }
    allow(Rails.logger).to receive(:info).and_call_original
    allow(Rails.logger).to receive(:error).and_call_original
  end

  def run = Canary.new.run

  def counts = DailyAggregate.where(kind: "canary").to_h { |row| [ row.key, row.count ] }

  def month = BudgetState.for_month!

  def kept(conversation) = [ conversation.messages.count, conversation.turns.count, TraceEvent.count, UsageRecord.count ]

  describe "a run that passes" do
    it "asks on the economy model in normal mode, finds the marker, counts a pass and tells the monitor all is well" do
      result = run

      expect(result).to have_attributes(passed: true, mode: "economy")
      expect(fake.requests.first.body).to include(model: "claude-haiku-5-5")
      expect(fake.requests.first.body.fetch(:messages).last.fetch(:content).to_s).to include(Canary::QUESTION)
      expect(counts).to eq("passed" => 1)
      expect(beat).to have_been_requested.once
      expect(failure).not_to have_been_requested
      expect(Rails.logger).to have_received(:info).with(/\Acanary: passed in \d+ ms \(mode economy\)\z/)
    end

    it "elicits the street of the store's address, read from the store sheet" do
      expect(Canary.marker).to eq("Rua dos Boticários")
    end

    it "keeps only its conversation, its visitor and the day's count; its calls stay in the month's spend" do
      run

      visitor = Visitor.find_by!(channel: "system")
      conversation = Conversation.find_by!(visitor:)
      expect(kept(conversation)).to eq([ 0, 0, 0, 0 ])
      expect(month.spent_usd).to be_positive
    end

    it "runs on the economy model in the month's economy too, the gate open" do
      Rails.configuration.x.economy_allowed = true
      month.update!(spent_usd: BigDecimal("7"))

      expect(run).to have_attributes(passed: true, mode: "economy")
      expect(fake.requests.first.body).to include(model: "claude-haiku-5-5")
    end

    it "broadcasts nothing: no page follows the system visitor's conversation" do
      allow(ActionCable.server).to receive(:broadcast)

      run

      expect(ActionCable.server).not_to have_received(:broadcast)
    end

    it "makes one system visitor and one conversation, which the next runs find again" do
      responses.push(reply(answer, model: "claude-haiku-5-5"))

      2.times { run }

      expect(Visitor.where(channel: "system").count).to eq(1)
      expect(Conversation.joins(:visitor).where(visitors: { channel: "system" }).count).to eq(1)
      expect(counts).to eq("passed" => 2)
    end

    it "is the same system visitor however many callers ask at once (NFR-02)" do
      first = Visitor.canary!

      expect(Visitor.canary!).to eq(first)
      expect(first).to have_attributes(channel: "system", identity_hash: Visitor::CANARY)
    end
  end

  describe "paused, it passes on a pause's fixed text, with no model call" do
    let(:responses) { [] }

    it "at the month's cap" do
      month.update!(spent_usd: BigDecimal("10"))

      expect(run).to have_attributes(passed: true, mode: "paused")
      expect(fake.requests).to be_empty
      expect(beat).to have_been_requested.once
    end

    it "at the day's slice while ADR-0003's gate keeps the economy closed" do
      month.update!(day: Date.current, day_spent_usd: BigDecimal("0.5"))

      expect(run).to have_attributes(passed: true, mode: "paused")
      expect(fake.requests).to be_empty
    end

    it "when the operator forced the pause" do
      Budget.force!("paused")

      expect(run).to have_attributes(passed: true, mode: "paused")
      expect(fake.requests).to be_empty
    end
  end

  describe "a run that fails" do
    it "fails when the reply lacks the marker, counts a failure and tells the monitor why, keeping nothing" do
      responses.replace([ reply("[pt] Olá! Em que posso ajudar?", model: "claude-haiku-5-5") ])

      result = run

      expect(result).to have_attributes(passed: false, reason: "the reply lacks the marker (outcome replied)")
      expect(counts).to eq("failed" => 1)
      expect(failure.with(body: "canary: the reply lacks the marker (outcome replied)")).to have_been_requested.once
      expect(beat).not_to have_been_requested
      expect(kept(Conversation.sole)).to eq([ 0, 0, 0, 0 ])
      expect(Rails.logger).to have_received(:error).with("canary: failed: the reply lacks the marker (outcome replied)")
    end

    it "fails when the model cannot answer, naming the turn's outcome" do
      responses.replace(Array.new(3) { { status: 529, body: { type: "error", error: { type: "overloaded_error", message: "Overloaded" } } } })

      expect(run).to have_attributes(passed: false, reason: "the reply lacks the marker (outcome model_error)")
      expect(counts).to eq("failed" => 1)
    end

    it "fails when the reply took longer than 20 seconds" do
      allow(TurnProcessor).to receive(:new).and_wrap_original do |original, *args, **kwargs|
        travel(21.seconds)
        original.call(*args, **kwargs)
      end

      expect(run).to have_attributes(passed: false, reason: a_string_matching(/\Athe reply took 2\d{4} ms, over 20000\z/))
    end

    it "fails when the turn breaks, naming the error's class alone, and keeps nothing of it" do
      allow(Guardrail).to receive(:new).and_raise(ActiveRecord::ConnectionFailed, "words of no one")

      result = run

      expect(result).to have_attributes(passed: false, reason: "the run broke: ActiveRecord::ConnectionFailed")
      expect(failure.with(body: "canary: the run broke: ActiveRecord::ConnectionFailed")).to have_been_requested.once
      expect(kept(Conversation.sole)).to eq([ 0, 0, 0, 0 ])
    end

    it "fails when the run breaks before any turn, as when the system visitor cannot be read" do
      allow(Visitor).to receive(:canary!).and_raise(ActiveRecord::ConnectionFailed, "gone")

      expect(run).to have_attributes(passed: false, reason: "the run broke: ActiveRecord::ConnectionFailed")
      expect(fake.requests).to be_empty
    end

    # AdvisoryLock.try_hold's own spec holds the lock from another session
    # (spec/models/conversation_lock_spec.rb); here the try finds it held.
    it "fails at once, without waiting, while an earlier run still holds the canary's conversation" do
      conversation = Conversation.current_for!(Visitor.canary!)
      allow(AdvisoryLock).to receive(:try_hold).with("conversation:#{conversation.id}").and_return(false)

      expect(run).to have_attributes(passed: false, reason: "an earlier run still holds the canary's conversation")
      expect(fake.requests).to be_empty
      expect(counts).to eq("failed" => 1)
      expect(failure.with(body: "canary: an earlier run still holds the canary's conversation")).to have_been_requested.once
    end

    it "still tells the monitor when the day's count cannot be written" do
      allow(DailyAggregate).to receive(:add!).and_raise(ActiveRecord::ConnectionFailed, "gone")

      expect(run).to have_attributes(passed: true)
      expect(beat).to have_been_requested.once
      expect(Rails.logger).to have_received(:error).with("canary: the day's count not written, ActiveRecord::ConnectionFailed")
    end
  end

  it "clears what an earlier run left, so the model reads no history and the conversation never grows" do
    conversation = Conversation.current_for!(Visitor.canary!)
    left = Message.record_inbound!(conversation:, external_id: "canary-left", body: Canary::QUESTION, source: "canary")
    Turn.for_inbound!(left).update!(state: "running")

    expect(run).to have_attributes(passed: true)
    expect(fake.requests.first.body.fetch(:messages).size).to eq(1)
    expect(kept(conversation)).to eq([ 0, 0, 0, 0 ])
  end

  # A rehearsal host has no monitor (design §8): the canary runs and counts
  # all the same.
  it "runs and counts with no monitor URL, sending nothing" do
    Rails.configuration.x.monitor_url = nil

    expect(run).to have_attributes(passed: true)
    expect(counts).to eq("passed" => 1)
    expect(a_request(:any, /monitor\.example/)).not_to have_been_made
  end

  it "is scheduled every ten minutes in production, beside the Telegram watch (config/recurring.yml)" do
    schedule = YAML.safe_load(ERB.new(Rails.root.join("config/recurring.yml").read).result).fetch("production")

    expect(schedule.fetch("canary")).to eq("class" => "CanaryJob", "schedule" => "every 10 minutes")
    expect(schedule.fetch("telegram_watch")).to include("class" => "TelegramWatchJob")
    expect(Fugit.parse_cronish(schedule.dig("telegram_watch", "schedule")).rough_frequency).to eq(600)
  end

  it "runs in its job, which a failure never makes try again (the next run is ten minutes away) and still tells the monitor" do
    allow(Canary).to receive(:new).and_raise(ActiveRecord::ConnectionFailed, "gone")

    expect { CanaryJob.perform_now }.not_to raise_error
    expect(enqueued_jobs).to be_empty
    expect(failure.with(body: "canary: not run, ActiveRecord::ConnectionFailed")).to have_been_requested.once
    expect(Rails.logger).to have_received(:error).with("canary: not run, ActiveRecord::ConnectionFailed")
  end
end
