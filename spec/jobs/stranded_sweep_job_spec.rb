require "rails_helper"
require "fugit"

# NFR-03's sweep (M4-4; the owner, 2026-11-15): "never a silent drop" covers
# every message the application accepted. A Telegram update left unread, a
# turn left without any reply and a stored Telegram reply left pending, each
# stopped for more than five minutes with nothing at work on it, are taken up
# again by the job that runs them, and that job's own bound (three reads,
# three runs, three attempts) decides whether it is run again or given up
# with a fixed line (review findings of pull requests #11, #18, #32 and #33).
RSpec.describe "NFR-03 StrandedSweepJob, nothing left without an answer" do
  include ActiveJob::TestHelper
  include ModelResponses
  include TelegramBotApi

  let!(:sent) { stub_bot_api }
  let(:visitor) { create(:visitor) }
  let(:conversation) { create(:conversation, visitor:) }
  let(:lines) { [] }

  before do
    allow(Rails.logger).to receive(:info).and_call_original
    allow(Rails.logger).to receive(:info).with(/\Asweep:/) { |line| lines << line }
  end

  def inbound(text, conversation: self.conversation, at: Time.current)
    travel_to(at) { Turn.for_inbound!(Message.record_inbound!(conversation:, external_id: SecureRandom.uuid, body: text)) }
  end

  def enqueued(job) = enqueued_jobs.select { |entry| entry[:job] == job }.map { |entry| entry[:args] }

  def sweep = StrandedSweepJob.perform_now

  describe "a turn left without a reply" do
    it "is taken up again once stopped for more than five minutes, and not before" do
      stale = inbound("oi", at: 6.minutes.ago)
      inbound("tem dipirona?", conversation: create(:conversation, visitor: create(:visitor)), at: 4.minutes.ago)

      sweep

      expect(enqueued(ProcessTurnJob)).to eq([ [ stale.id ] ])
      expect(lines).to eq([ "sweep: taken up again 0 updates, 1 conversations, 0 visitors' replies" ])
    end

    it "is taken up by one job a conversation, its latest turn's, which answers the earlier ones first (design §6.3)" do
      inbound("oi", at: 8.minutes.ago)
      latest = inbound("tem dipirona?", at: 7.minutes.ago)

      sweep

      expect(enqueued(ProcessTurnJob)).to eq([ [ latest.id ] ])
    end

    it "is answered when the job the sweep took it up with runs, so the page's pensando… ends (#18's V3)" do
      allow(AgentRunner).to receive(:default_client) { FakeModel.new([ reply("[pt] Olá!") ]).client }
      turn = inbound("oi", at: 6.minutes.ago)

      sweep
      perform_enqueued_jobs(only: ProcessTurnJob)

      expect(turn.reload).to have_attributes(state: "replied", runs: 1)
      expect(turn.outbound_message.body).to end_with("Olá!")
    end

    it "gets the fallback when it ran three times already, a turn whose worker died on each run" do
      turn = inbound("oi", at: 30.minutes.ago)
      turn.update_columns(runs: 3, state: "running", updated_at: 20.minutes.ago)
      expect_any_instance_of(AgentRunner).not_to receive(:run)

      sweep
      perform_enqueued_jobs(only: ProcessTurnJob)

      expect(turn.reload.outbound_message.body).to end_with(FixedReply.fallback("pt-BR"))
    end

    it "is left when it has its reply, when a run of it is under way (its row moved in the last five minutes), or when its conversation's lock is held" do
      replied = inbound("oi", at: 10.minutes.ago)
      Message.record_outbound!(turn: replied, body: "Olá!")
      running = inbound("oi", conversation: create(:conversation, visitor: create(:visitor)), at: 10.minutes.ago)
      running.update_columns(state: "running", updated_at: 1.minute.ago)
      busy = inbound("oi", conversation: create(:conversation, visitor: create(:visitor)), at: 10.minutes.ago)
      allow(AdvisoryLock).to receive(:free?).and_call_original
      allow(AdvisoryLock).to receive(:free?).with("conversation:#{busy.conversation_id}").and_return(false)

      sweep

      expect(enqueued(ProcessTurnJob)).to be_empty
      expect(lines).to be_empty
    end
  end

  describe "a Telegram update left unread" do
    let(:person) { Digest::SHA256.hexdigest("person") }

    def unread(update_id, identity_hash: person, at: 6.minutes.ago)
      travel_to(at) { WebhookEvent.record!(update_id:, kind: "message", payload: "{}", identity_hash:) }
    end

    it "is read again once stopped for more than five minutes, by one job a person, the person's latest update's, which reads the earlier ones first" do
      unread(734_120_001, at: 9.minutes.ago)
      latest = unread(734_120_002, at: 8.minutes.ago)
      unread(734_120_003, at: 4.minutes.ago)

      sweep

      expect(enqueued(TelegramUpdateJob)).to eq([ [ latest.id ] ])
      expect(lines).to eq([ "sweep: taken up again 1 updates, 0 conversations, 0 visitors' replies" ])
    end

    it "is read again by a job of its own when it names no person (an update the bot drops)" do
      first = unread(734_120_001, identity_hash: nil)
      second = unread(734_120_002, identity_hash: nil)

      sweep

      expect(enqueued(TelegramUpdateJob)).to contain_exactly([ first.id ], [ second.id ])
    end

    it "is left when it was read or a read of it is under way (its row moved in the last five minutes), or when its person's lock is held" do
      unread(734_120_001).strip!("processed")
      unread(734_120_002, identity_hash: Digest::SHA256.hexdigest("other")).update_columns(updated_at: 1.minute.ago)
      busy = unread(734_120_003, identity_hash: Digest::SHA256.hexdigest("busy"))
      allow(AdvisoryLock).to receive(:free?).and_call_original
      allow(AdvisoryLock).to receive(:free?).with("telegram:#{busy.identity_hash}").and_return(false)

      sweep

      expect(enqueued(TelegramUpdateJob)).to be_empty
    end
  end

  describe "a Telegram reply left pending" do
    let(:visitor) { create(:visitor, channel: "telegram", telegram_chat_id: "7341200001", agreed_at: 1.hour.ago) }

    def pending(at: 6.minutes.ago, next_attempt_at: nil, conversation: self.conversation)
      turn = inbound("oi", conversation:, at:)
      message = travel_to(at) { Message.record_outbound!(turn:, body: "Olá!") }
      message.update_columns(next_attempt_at:)
      message
    end

    it "is sent again once stopped for more than five minutes, by one job a visitor" do
      pending(at: 9.minutes.ago)
      pending(at: 8.minutes.ago)

      sweep

      expect(enqueued(TelegramReplyJob)).to eq([ [ visitor.id ] ])
    end

    it "is sent again when the job that sends it is gone, and leaves for the chat" do
      reply = pending

      sweep
      perform_enqueued_jobs(only: TelegramReplyJob)

      expect(reply.reload.status).to eq "sent"
      expect(sent.map { |body| body["text"] }).to eq([ "Olá!" ])
    end

    # Review finding V3 of pull request #48: a reply whose visitor's chat
    # does not decrypt stayed pending, taken up again at every pass.
    it "is taken up once when its visitor's chat cannot be read: it fails, and the next pass leaves it" do
      reply = pending
      allow(Rails.logger).to receive(:error)
      other_keys = ActiveRecord::Encryption::DerivedSecretKeyProvider.new("another-primary-key-for-the-spec")

      ActiveRecord::Encryption.with_encryption_context(key_provider: other_keys) do
        sweep
        perform_enqueued_jobs(only: TelegramReplyJob)
      end
      clear_enqueued_jobs
      sweep

      expect(reply.reload.status).to eq "failed"
      expect(enqueued(TelegramReplyJob)).to be_empty
    end

    it "is left while it waits for its next attempt's time, or when its person's send lock is held" do
      pending(next_attempt_at: 1.minute.from_now)
      busy = create(:visitor, channel: "telegram", identity_hash: Digest::SHA256.hexdigest("busy"), telegram_chat_id: "7341200002",
                              agreed_at: 1.hour.ago)
      pending(conversation: create(:conversation, visitor: busy))
      allow(AdvisoryLock).to receive(:free?).and_call_original
      allow(AdvisoryLock).to receive(:free?).with("telegram-send:#{busy.identity_hash}").and_return(false)

      sweep

      expect(enqueued(TelegramReplyJob)).to be_empty
    end
  end

  it "goes on to the rest when one of its three looks breaks, with a line naming it by the error's class" do
    errors = []
    allow(Rails.logger).to receive(:error) { |line| errors << line }
    allow(WebhookEvent).to receive(:received).and_raise(ActiveRecord::StatementInvalid, "relation does not exist")
    turn = inbound("oi", at: 6.minutes.ago)

    sweep

    expect(enqueued(ProcessTurnJob)).to eq([ [ turn.id ] ])
    expect(errors).to eq([ "sweep: updates not looked at, ActiveRecord::StatementInvalid" ])
  end

  # The test database has no Solid Queue tables, so the task is read as Solid
  # Queue's own checks read it (SolidQueue::RecurringTask's validations).
  it "runs every minute in production, in the job container" do
    task = YAML.safe_load(ERB.new(Rails.root.join("config/recurring.yml").read).result, aliases: true)
               .fetch("production").fetch("stranded_sweep")
    schedule = Fugit.parse(task.fetch("schedule"), multi: :fail)

    expect(task.fetch("class")).to eq("StrandedSweepJob")
    expect(schedule.rough_frequency).to eq 1.minute
  end
end
