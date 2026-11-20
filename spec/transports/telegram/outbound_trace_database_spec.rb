require "rails_helper"

# A Telegram reply's way in its turn's trace when the database breaks the
# trace's read (FR-19, FR-12): the reply's status is written all the same,
# and the way is closed whenever it can be read. These run outside the
# transactional fixtures, as the jobs that send run outside any transaction:
# a statement the database breaks aborts the transaction it runs in, and the
# trace's read runs in none (TraceRecorder.way).
RSpec.describe "FR-19 FR-12 Telegram::Outbound, a reply's way in the trace when the database breaks the trace's read" do
  include TelegramBotApi

  self.use_transactional_tests = false

  let!(:sent) { stub_bot_api }
  let(:visitor) { create(:visitor, channel: "telegram", telegram_chat_id: "7341200009", agreed_at: Time.current) }
  let(:conversation) { create(:conversation, visitor:) }
  let(:outbound) { Telegram::Outbound.new }
  let(:lines) { [] }

  before { allow(Rails.logger).to receive(:error) { |line| lines << line } }

  after do
    ActiveRecord::Base.connection.execute("ALTER TABLE conversations DROP COLUMN IF EXISTS migration_probe")
    Visitor.where(id: visitor.id).delete_all
    # No later spec meets a statement this file's migration made stale.
    ActiveRecord::Base.connection_pool.disconnect!
    Conversation.reset_column_information
  end

  # A stored reply and its open way, as a turn's run leaves them.
  def reply(body)
    inbound = create(:message, conversation:, external_id: "#{visitor.id}:#{SecureRandom.random_number(10**9)}")
    Message.record_outbound!(turn: Turn.for_inbound!(inbound), body:).tap do |message|
      TraceEvent.create!(turn_id: message.turn_id, trace_id: SecureRandom.hex(16), span_id: SecureRandom.hex(8),
                         name: "balcao.delivery", started_at: Time.current)
    end
  end

  def delivery_of(message) = TraceEvent.find_by(turn_id: message.turn_id, name: "balcao.delivery")

  # Every read of a turn breaks in the database (a lock or a statement
  # timeout during a deploy's migration; here a division by zero), whatever
  # code reads it, as an error raised in Ruby does not: the fix review's R1
  # on pull request #52 found the examples broke one way of reading it, which
  # the code before #48's H3 did not use.
  def turn_read_breaks
    allow_any_instance_of(ActiveRecord::ConnectionAdapters::PostgreSQLAdapter).to receive(:select_all)
      .and_wrap_original do |original, arel, name = nil, *rest, **options|
        original.receiver.execute("SELECT 1/0") if name == "Turn Load"
        original.call(arel, name, *rest, **options)
      end
  end

  # Review finding C1 and the hunter's H1 on pull request #52: the turn was
  # read for the trace inside the transaction of the reply's status, so a
  # statement the database broke there aborted the transaction, and its
  # COMMIT rolled the status back in silence: a reply Telegram took stayed
  # pending, for the sweep minutes later.
  it "keeps a reply sent though the database breaks the read of its turn for the trace" do
    message = reply("Temos, sim.")
    turn_read_breaks

    outbound.deliver_pending(visitor)

    expect(message.reload.status).to eq "sent"
    expect(lines).to include("trace: span balcao.delivery not read: ActiveRecord::StatementInvalid")
  end

  # The hunter's H3 on pull request #48: a database error on that read broke
  # the delivery, so a refusal's own line was lost and an attempt was counted
  # on a reply already failed; the fix review's sister: the same read for a
  # visitor whose chat does not decrypt. The verifier's V1 on pull request
  # #52: these examples stubbed Message#turn, which the fix no longer calls,
  # so they passed whatever guarded the read; they break the read itself.
  it "fails a refused reply with its line though its turn cannot be read for the trace" do
    message = reply("Temos, sim.")
    stub_request(:post, bot_api_url("sendMessage")).to_return(bot_api_error(403, "Forbidden: bot was blocked by the user"))
    turn_read_breaks

    outbound.deliver_pending(visitor)

    expect(message.reload).to have_attributes(status: "failed", send_attempts: 1)
    expect(lines).to include("telegram reply #{message.id}: failed after 1 attempt, Telegram::Client::Error (403)")
  end

  it "fails the replies of a visitor whose chat does not decrypt though their turns cannot be read for the trace" do
    message = reply("Temos, sim.")
    turn_read_breaks
    other_keys = ActiveRecord::Encryption::DerivedSecretKeyProvider.new("another-primary-key-for-the-spec")

    ActiveRecord::Encryption.with_encryption_context(key_provider: other_keys) { outbound.deliver_pending(Visitor.find(visitor.id)) }

    expect(message.reload.status).to eq "failed"
  end

  # The verifier's V3 on pull request #52: Kamal runs a deploy's migration in
  # the new web container while the old job container still sends replies.
  # A column added to the conversations makes the old connections' prepared
  # `SELECT *` of them stale, and Active Record prepares it again only outside
  # a transaction, so the turn's conversation, read for the trace inside the
  # transaction of the reply's status, failed at every delivery of that
  # worker, each leaving the reply's way open until the old container stopped.
  it "closes the way of a reply sent after a migration added a column to the conversations" do
    first = reply("Primeira.")
    # The second waits for its time while the first leaves, stored before the migration.
    second = reply("Segunda.").tap { |message| message.update_columns(next_attempt_at: 1.minute.from_now) }
    outbound.deliver_pending(visitor)
    expect([ first.reload.status, delivery_of(first).finished_at ]).to match([ "sent", be_present ])

    ActiveRecord::Base.connection.execute("ALTER TABLE conversations ADD COLUMN migration_probe integer")
    second.update_columns(next_attempt_at: nil)
    outbound.deliver_pending(visitor)

    expect(second.reload.status).to eq "sent"
    expect(delivery_of(second).finished_at).to be_present
  end
end
