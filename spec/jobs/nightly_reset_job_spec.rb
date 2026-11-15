require "rails_helper"
require "fugit"

# FR-15: every day at 03:00 São Paulo the fictional data is rebuilt and what
# passed its seven days is deleted, each record by its own age (threat model
# SR-31, /privacy): reservations past their pickup deadline expire and give
# their units back, the catalogue's stock returns to the seed less what open
# reservations hold, and messages, turns, traces and usage records older than
# seven days go, with conversations whose last message is, reservations seven
# days past their deadline and visitors not seen for seven days with all
# under them. The month's spend stays (FR-14).
RSpec.describe "FR-15 SR-31 the nightly reset and the seven-day purge" do
  let(:three_am) { Time.zone.local(2026, 11, 20, 3, 0) }
  let(:dipirona) { Product.find_by!(sku: "dipirona-500mg-10cp") }
  let(:seed_stock) { CatalogueSeed.entries.find { |entry| entry[:sku] == "dipirona-500mg-10cp" }.fetch(:stock) }

  before { travel_to(three_am - 9.days) { CatalogueSeed.seed! } }

  def at(time, &) = travel_to(time, &)

  def run = at(three_am) { NightlyResetJob.perform_now }

  def reserve(quantity:, made:, pickup_until:, visitor: create(:visitor))
    at(made) do
      conversation = Conversation.current_for!(visitor)
      turn = Turn.for_inbound!(Message.record_inbound!(conversation:, external_id: SecureRandom.uuid, body: "reserva"))
      dipirona.with_lock do
        dipirona.update!(stock: dipirona.stock - quantity)
        Reservation.create_once!(turn:, product: dipirona, quantity:, pickup_until:)
      end
    end
  end

  def message(conversation, at:, text: "oi")
    at(at) { Message.record_inbound!(conversation:, external_id: SecureRandom.uuid, body: text) }
  end

  def turn_of(conversation, at:)
    at(at) { Turn.for_inbound!(Message.record_inbound!(conversation:, external_id: SecureRandom.uuid, body: "oi")) }
  end

  describe "the reservations and the stock" do
    it "keeps open, with its units held, a reservation made at 18:00 with pickup until the next business day" do
      reservation = reserve(quantity: 2, made: three_am - 9.hours, pickup_until: (three_am + 1.day).change(hour: 20))

      run

      expect(reservation.reload.state).to eq("open")
      expect(dipirona.reload.stock).to eq(seed_stock - 2)
    end

    it "expires a reservation past its pickup deadline and gives its units back to the stock" do
      reservation = reserve(quantity: 3, made: three_am - 2.days, pickup_until: three_am - 7.hours)

      run

      expect(reservation.reload.state).to eq("expired")
      expect(dipirona.reload.stock).to eq(seed_stock)
    end

    it "brings the stock back to the seed's, less the units the open reservations hold" do
      reserve(quantity: 2, made: three_am - 1.hour, pickup_until: three_am + 1.day)
      dipirona.update!(stock: 1, price: BigDecimal("99.90"))

      run

      expect(dipirona.reload).to have_attributes(stock: seed_stock - 2, price: BigDecimal("7.90"))
    end

    it "deletes a reservation seven days past its pickup deadline, and keeps the product" do
      old = reserve(quantity: 1, made: three_am - 10.days, pickup_until: three_am - 8.days)
      recent = reserve(quantity: 1, made: three_am - 6.days, pickup_until: three_am - 6.days)

      run

      expect(Reservation.where(id: old.id)).to be_empty
      expect(recent.reload.state).to eq("expired")
      expect(dipirona.reload).to be_persisted
    end
  end

  describe "the purge" do
    it "deletes a visitor last seen 8 days ago with everything under it (SR-31, /privacy)" do
      visitor = create(:visitor, last_seen_at: three_am - 8.days)
      conversation = create(:conversation, visitor:)
      turn = turn_of(conversation, at: three_am - 8.days)
      at(three_am - 8.days) { create(:trace_event, turn:) && create(:usage_record, turn:) }

      run

      expect(Visitor.where(id: visitor.id)).to be_empty
      expect([ Conversation, Message, Turn, TraceEvent, UsageRecord ].map(&:count)).to all(eq(0))
    end

    it "keeps a conversation opened 8 days ago and written to yesterday, without its messages older than 7 days" do
      visitor = create(:visitor, last_seen_at: three_am - 1.day)
      conversation = at(three_am - 8.days) { create(:conversation, visitor:) }
      old = message(conversation, at: three_am - 8.days)
      yesterday = message(conversation, at: three_am - 1.day)

      run

      expect(conversation.reload).to be_persisted
      expect(conversation.messages).to contain_exactly(yesterday)
      expect(Message.where(id: old.id)).to be_empty
    end

    it "deletes a conversation once its last message is older than 7 days, and its trace link stops answering" do
      visitor = create(:visitor, last_seen_at: three_am - 1.day)
      conversation = at(three_am - 10.days) { create(:conversation, visitor:) }
      message(conversation, at: three_am - 8.days)

      run

      expect(Conversation.find_by_trace_token(conversation.trace_token)).to be_nil
      expect(visitor.reload).to be_persisted
    end

    it "keeps a conversation opened within the 7 days, even with no message yet" do
      conversation = at(three_am - 2.days) { create(:conversation, visitor: create(:visitor, last_seen_at: three_am - 2.days)) }

      run

      expect(conversation.reload).to be_persisted
    end

    it "deletes turns, traces and usage records older than 7 days, each by its own age, and keeps the newer" do
      conversation = create(:conversation, visitor: create(:visitor, last_seen_at: three_am - 1.hour))
      old_turn = turn_of(conversation, at: three_am - 8.days)
      at(three_am - 8.days) { create(:trace_event, turn: old_turn) && create(:usage_record, turn: old_turn) }
      new_turn = turn_of(conversation, at: three_am - 6.days)
      new_span = at(three_am - 6.days) { create(:trace_event, turn: new_turn) }
      new_usage = at(three_am - 6.days) { create(:usage_record, turn: new_turn) }
      old_span = at(three_am - 8.days) { create(:trace_event, turn: new_turn) }

      run

      expect(Turn.all).to contain_exactly(new_turn)
      expect(TraceEvent.all).to contain_exactly(new_span)
      expect(UsageRecord.all).to contain_exactly(new_usage)
      expect(TraceEvent.where(id: old_span.id)).to be_empty
    end

    # Review finding V1 of pull request #32: an image before PR-18 (one the
    # deploy's window still runs, or one returned to) writes bodies in plain
    # text, which the migration that encrypted the stored ones never visits
    # again; the night encrypts them (SR-41).
    it "encrypts the bodies an image before PR-18 wrote in plain text, and leaves the encrypted ones as they were" do
      conversation = create(:conversation)
      plain = SecureRandom.uuid
      Message.connection.execute(Message.sanitize_sql([ <<~SQL.squish, plain, conversation.id ]))
        INSERT INTO messages (id, conversation_id, channel, direction, author, source, body, created_at, updated_at)
        VALUES (?, ?, 'web', 'inbound', 'visitor', 'text', 'escrito em texto puro', now(), now())
      SQL
      encrypted = message(conversation, at: three_am - 1.hour, text: "cifrado")
      stored = ->(id) { Message.connection.select_value(Message.sanitize_sql([ "SELECT body FROM messages WHERE id = ?", id ])) }
      before = stored.(encrypted.id)

      run

      expect(stored.(plain)).not_to include("texto puro")
      expect(Message.find(plain).body).to eq("escrito em texto puro")
      expect(stored.(encrypted.id)).to eq(before)
    end

    # FR-19: a stored Telegram update holds only its id and its kind once read,
    # and goes at seven days, read or not.
    it "deletes the stored Telegram updates older than 7 days, read or not, and keeps the newer" do
      unread = at(three_am - 8.days) { create(:webhook_event) }
      read = at(three_am - 8.days) { create(:webhook_event).tap { |event| event.strip!("processed") } }
      recent = at(three_am - 6.days) { create(:webhook_event) }

      run

      expect(WebhookEvent.all).to contain_exactly(recent)
      expect(WebhookEvent.where(id: [ unread.id, read.id ])).to be_empty
    end

    # FR-14's counters (design §10, note of 2026-11-14, PR-17): kept in the
    # cache under the IP address and the identity's hash, outside the rows a
    # deletion takes (FR-05), and kept by Solid Cache alone two weeks or more.
    # The test database has only the primary's tables: the cache's are made
    # in the example's transaction, as Solid Cache writes there in test.
    # Review finding C4 of pull request #30, the owner's word of 2026-11-15
    # (question 21): a turn that fails for good leaves a failed execution in
    # Solid Queue, the dead letter, whose stored error may quote what the
    # visitor wrote; it goes at seven days, with its job. The test database
    # has only the primary's tables: the queue's are made inside the
    # example's transaction, which takes them away again.
    describe "the failed jobs" do
      before do
        ActiveRecord::Migration.suppress_messages { load Rails.root.join("db/queue_schema.rb") }
        [ SolidQueue::Job, SolidQueue::FailedExecution ].each(&:reset_column_information)
        allow(NightlyResetJob).to receive(:queue_adapter).and_return(ActiveJob::QueueAdapters::SolidQueueAdapter.new)
      end

      def failed_job(at:)
        job = SolidQueue::Job.create!(queue_name: "default", class_name: "ProcessTurnJob", arguments: "{}",
                                      active_job_id: SecureRandom.uuid, scheduled_at: at, created_at: at)
        SolidQueue::FailedExecution.where(job_id: job.id).delete_all
        SolidQueue::ReadyExecution.where(job_id: job.id).delete_all
        SolidQueue::FailedExecution.create!(job:, error: { exception_class: "PG::CheckViolation", message: "Failing row contains (oi)" }, created_at: at)
        job
      end

      it "deletes the failed jobs older than seven days with their stored errors, and keeps the newer" do
        old = failed_job(at: three_am - 8.days)
        recent = failed_job(at: three_am - 6.days)

        run

        expect(SolidQueue::Job.pluck(:id)).to eq([ recent.id ])
        expect(SolidQueue::FailedExecution.pluck(:job_id)).to eq([ recent.id ])
        expect(SolidQueue::Job.where(id: old.id)).to be_empty
      end
    end

    describe "the limits' counters" do
      let(:store) { SolidCache::Store.new(namespace: "test") }

      before do
        ActiveRecord::Migration.suppress_messages { load Rails.root.join("db/cache_schema.rb") }
        SolidCache::Entry.reset_column_information
        allow(Rack::Attack.cache).to receive(:store).and_return(store)
      end

      # Solid Cache dates a row by the database's clock, so the rows are dated
      # back by hand.
      def written(key, at:) = SolidCache::Entry.where(key: "test:#{key}").update_all(created_at: at)

      it "deletes the counters older than seven days, a live one first written then included, and keeps the rest of the cache" do
        EdgeLimits.over?("visitor/day", "old-identity")
        EdgeLimits.over?("visitor/day", "new-identity")
        EdgeLimits.over?("ip/turns", "203.0.113.9")
        store.write("calendar", "not a counter")
        written("limits:visitor/day:old-identity", at: three_am - 8.days)
        written("limits:visitor/day:new-identity", at: three_am - 6.days)
        written("limits:ip/turns:203.0.113.9", at: three_am - 8.days)
        written("calendar", at: three_am - 8.days)
        # Solid Cache never moves a row's creation time, so a window that
        # lives on restarts at most once a week.
        EdgeLimits.over?("ip/turns", "203.0.113.9")
        expect(SolidCache::Entry.where(key: "test:limits:ip/turns:203.0.113.9").pick(:created_at)).to eq(three_am - 8.days)

        run

        expect(SolidCache::Entry.pluck(:key)).to include("test:limits:visitor/day:new-identity", "test:calendar")
        expect(SolidCache::Entry.pluck(:key).grep(/limits/)).to eq([ "test:limits:visitor/day:new-identity" ])
      end
    end

    it "keeps the month's spend, which the ledger needs past the usage records' seven days (FR-14)" do
      state = at(three_am - 19.days) { BudgetState.for_month!.tap { |month| month.update!(spent_usd: BigDecimal("3.5")) } }

      run

      expect(state.reload.spent_usd).to eq(BigDecimal("3.5"))
    end
  end

  it "ends, when retried after failing midway, as one clean run would (each step is idempotent)" do
    visitor = create(:visitor, last_seen_at: three_am - 8.days)
    held = reserve(quantity: 2, made: three_am - 1.hour, pickup_until: three_am + 1.day)
    past = reserve(quantity: 3, made: three_am - 2.days, pickup_until: three_am - 7.hours)
    allow(CatalogueSeed).to receive(:seed!).and_raise(ActiveRecord::ConnectionFailed, "gone")

    expect { run }.to have_enqueued_job(NightlyResetJob)

    allow(CatalogueSeed).to receive(:seed!).and_call_original
    run
    run

    expect(Visitor.where(id: visitor.id)).to be_empty
    expect(held.reload.state).to eq("open")
    expect(past.reload.state).to eq("expired")
    expect(dipirona.reload.stock).to eq(seed_stock - 2)
  end

  # Review finding S5 of pull request #29 and the triage's A-V1: one step
  # that broke (a delete past the statement timeout, the cache's database
  # down) stopped every step after it, the catalogue's reset and the
  # plain-body sweep among them.
  it "runs every step when one fails, names that one in its line, and raises at the end for the retry" do
    allow(Rails.logger).to receive(:info)
    visitor = create(:visitor, last_seen_at: three_am - 8.days)
    dipirona.update!(stock: 1)
    allow(Message).to receive(:where).and_call_original
    allow(Message).to receive(:where).with(created_at: ...(three_am - 7.days)).and_raise(ActiveRecord::StatementTimeout, "canceling")
    allow(Message).to receive(:encrypt_plain_bodies).and_return(2)
    allow(EdgeLimits).to receive(:purge).and_return(3)

    expect { run }.to have_enqueued_job(NightlyResetJob)

    expect(Visitor.where(id: visitor.id)).to be_empty
    expect(dipirona.reload.stock).to eq(seed_stock)
    expect(Message).to have_received(:encrypt_plain_bodies)
    expect(Rails.logger).to have_received(:info).with(
      a_string_including("deleted 1 visitors", "messages failed: ActiveRecord::StatementTimeout", "3 limit counters",
                         "encrypted 2 plain bodies")
    )
  end

  # Review findings V2 and M5 of pull request #32: the counters' purge ran on
  # the cache's database before the catalogue's reset, so a cache down at
  # 03:00 stopped the reset; it runs after the reset, its failure apart.
  it "resets the catalogue before it purges the limits' counters, and a failed purge of them stops nothing" do
    allow(Rails.logger).to receive(:info)
    dipirona.update!(stock: 1)
    allow(CatalogueSeed).to receive(:seed!).and_call_original
    allow(EdgeLimits).to receive(:purge).and_raise(ActiveRecord::ConnectionNotEstablished, "cache down")

    expect { run }.to have_enqueued_job(NightlyResetJob)

    expect(dipirona.reload.stock).to eq(seed_stock)
    expect(CatalogueSeed).to have_received(:seed!).ordered
    expect(EdgeLimits).to have_received(:purge).ordered
    expect(Rails.logger).to have_received(:info).with(a_string_including("limit counters failed: ActiveRecord::ConnectionNotEstablished"))
  end

  # Review finding S5 of pull request #29: one DELETE of a week's rows could
  # run past the 5 s statement timeout (SR-20); each goes in batches.
  it "deletes in batches, each its own statement" do
    stub_const("NightlyResetJob::BATCH", 2)
    conversation = create(:conversation, visitor: create(:visitor, last_seen_at: three_am - 1.hour))
    5.times { message(conversation, at: three_am - 8.days) }
    statements = []
    counting = ->(*, payload) { statements << payload[:sql] if payload[:sql].start_with?('DELETE FROM "messages"') }

    ActiveSupport::Notifications.subscribed(counting, "sql.active_record") { run }

    expect(Message.count).to eq(0)
    expect(statements.size).to eq(3)
  end

  it "says what it did in one line of counts, never a message or an identity (SR-30)" do
    allow(Rails.logger).to receive(:info)
    reserve(quantity: 3, made: three_am - 2.days, pickup_until: three_am - 7.hours)

    run

    expect(Rails.logger).to have_received(:info).with(
      /\Anightly reset: expired 1 reservations, reset \d+ products; deleted 0 visitors, 0 conversations, 0 messages, 0 turns, 0 spans, 0 usage records, 0 reservations, 0 stored updates, 0 failed jobs, 0 limit counters; encrypted 0 plain bodies\z/
    )
  end

  # The test database has no Solid Queue tables, so the task is read as Solid
  # Queue's own checks read it (SolidQueue::RecurringTask's validations).
  it "runs every day at 03:00 São Paulo, in the job container" do
    task = YAML.safe_load(ERB.new(Rails.root.join("config/recurring.yml").read).result, aliases: true)
               .fetch("production").fetch("nightly_reset")
    schedule = Fugit.parse(task.fetch("schedule"), multi: :fail)

    expect(task.fetch("class")).to eq("NightlyResetJob")
    expect(schedule).to be_an_instance_of(Fugit::Cron)
    expect(schedule.next_time(Time.zone.local(2026, 11, 14, 2, 59).utc).to_t.in_time_zone).to eq(Time.zone.local(2026, 11, 14, 3, 0))
    expect(schedule.next_time(Time.zone.local(2026, 11, 14, 3, 1).utc).to_t.in_time_zone).to eq(Time.zone.local(2026, 11, 15, 3, 0))
  end
end
