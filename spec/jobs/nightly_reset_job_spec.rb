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

  it "says what it did in one line of counts, never a message or an identity (SR-30)" do
    allow(Rails.logger).to receive(:info)
    reserve(quantity: 3, made: three_am - 2.days, pickup_until: three_am - 7.hours)

    run

    expect(Rails.logger).to have_received(:info).with(
      /\Anightly reset: expired 1 reservations, reset \d+ products; deleted 0 visitors, 0 conversations, 0 messages, 0 turns, 0 spans, 0 usage records, 0 reservations\z/
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
