require "rails_helper"

RSpec.describe "NFR-02 FR-19 visitor, one row per identity and channel" do
  let(:identity_hash) { Digest::SHA256.hexdigest("pepper" + "734120") }

  it "creates the visitor on first contact" do
    visitor = Visitor.identify!(channel: "telegram", identity_hash:)

    expect(visitor).to be_previously_new_record
    expect(visitor).to have_attributes(channel: "telegram", identity_hash:)
  end

  it "returns the visitor already known, by the read alone" do
    known = create(:visitor, channel: "telegram", identity_hash:)

    result, raised = with_raised_exceptions { Visitor.identify!(channel: "telegram", identity_hash:) }

    expect(result).to eq(known)
    expect(raised).not_to include(ActiveRecord::RecordNotUnique)
  end

  it "keeps the same hash on two channels apart" do
    create(:visitor, channel: "web", identity_hash:)

    expect(Visitor.identify!(channel: "telegram", identity_hash:)).to be_previously_new_record
  end

  it_behaves_like "an idempotency key", index: "index_visitors_on_channel_and_identity_hash" do
    let(:existing) { create(:visitor, channel: "telegram", identity_hash:) }
    let(:duplicate) { build(:visitor, channel: "telegram", identity_hash:) }
    let(:call_again) do
      lambda do
        # The read ran before another writer committed the same person's row.
        allow(Visitor).to receive(:find_by).and_return(nil)
        Visitor.identify!(channel: "telegram", identity_hash:)
      end
    end
  end
end

# FR-19's agreement first (the owner, 2026-11-14): a Telegram visitor's row
# is created by the agreement and holds the chat id a reply needs, encrypted
# (threat model SR-10, SR-41).
RSpec.describe "FR-19 SR-10 SR-41 a Telegram visitor, created by the agreement" do
  let(:identity_hash) { Digest::SHA256.hexdigest("pepper" + "734122") }

  it "creates the row with the time of the agreement, the chat id, and seen now" do
    at = Time.zone.local(2026, 11, 14, 15, 0)
    visitor = travel_to(at) { Visitor.agree!(identity_hash:, chat_id: 734_122) }

    expect(visitor).to be_previously_new_record
    expect(visitor).to have_attributes(channel: "telegram", identity_hash:, telegram_chat_id: "734122",
                                       agreed_at: at, last_seen_at: at)
  end

  it "keeps the chat id as ciphertext in the database, and reads it back as sent" do
    visitor = Visitor.agree!(identity_hash:, chat_id: 734_122)

    stored = Visitor.connection.select_value(Visitor.sanitize_sql([ "SELECT telegram_chat_id FROM visitors WHERE id = ?", visitor.id ]))
    expect(stored).not_to include("734122")
    expect(Visitor.find(visitor.id).telegram_chat_id).to eq("734122")
  end

  it "returns the row already there when two agreements race, as it was" do
    known = travel_to(1.hour.ago) { Visitor.agree!(identity_hash:, chat_id: 734_122) }
    allow(Visitor).to receive(:find_by).and_return(nil)

    again = Visitor.agree!(identity_hash:, chat_id: 734_122)

    expect(again).to eq(known)
    expect(again).not_to be_previously_new_record
    expect(again.agreed_at).to be_within(1.second).of(known.agreed_at)
  end
end

# Review finding N9 of pull request #7: the seven-day purge named
# conversations, turns, traces and usage records, never the visitor rows,
# so identities outlived the retention that /privacy promises.
RSpec.describe "FR-15 SR-31 visitors not seen for seven days, for the nightly purge" do
  it "picks the visitors last seen, or created and never seen, before the cutoff" do
    now = Time.zone.local(2026, 11, 20, 3, 0)
    gone = create(:visitor, last_seen_at: now - 8.days)
    never_seen = travel_to(now - 8.days) { create(:visitor, last_seen_at: nil) }
    recent = create(:visitor, last_seen_at: now - 6.days)
    created_old_seen_recently = travel_to(now - 30.days) { create(:visitor) }
    created_old_seen_recently.update!(last_seen_at: now - 1.day)

    travel_to(now) do
      expect(Visitor.unseen_for(7.days)).to contain_exactly(gone, never_seen)
    end
    expect(recent).to be_persisted
  end

  # Review finding R1 of pull request #7: nothing wrote last_seen_at, so a
  # visitor who kept writing counted as unseen seven days after first contact.
  it "counts a visitor as seen whenever it is identified again" do
    identity_hash = Digest::SHA256.hexdigest("pepper" + "734121")
    visitor = travel_to(Time.zone.local(2026, 11, 2, 10, 0)) { Visitor.identify!(channel: "telegram", identity_hash:) }
    travel_to(Time.zone.local(2026, 11, 9, 18, 0)) { Visitor.identify!(channel: "telegram", identity_hash:) }

    travel_to(Time.zone.local(2026, 11, 10, 3, 0)) do
      expect(Visitor.unseen_for(7.days)).not_to include(visitor)
    end
    expect(visitor.reload.last_seen_at).to eq(Time.zone.local(2026, 11, 9, 18, 0))
  end
end

RSpec.describe "FR-05 a visitor's data deleted on request" do
  let(:visitor) { create(:visitor) }
  let(:conversation) { create(:conversation, visitor:) }
  let(:turn) { create(:turn, inbound_message: create(:message, conversation:)) }
  let(:product) { create(:product, stock: 10) }

  it "releases the stock of open reservations, then deletes the visitor and everything under it" do
    create(:reservation, turn:, product:, quantity: 2)
    create(:reservation, turn:, product: create(:product, stock: 5), quantity: 3, state: "expired")
    closed = create(:conversation, visitor:, closed_at: 1.day.ago)
    create(:outbound_message, turn:)
    create(:trace_event, turn:)
    create(:usage_record, turn:)
    create(:message, conversation: closed)

    visitor.erase!

    expect(product.reload.stock).to eq(12)
    expect(Product.where.not(id: product.id).sole.stock).to eq(5)
    expect([ Visitor, Conversation, Message, Turn, TraceEvent, UsageRecord, Reservation ].map(&:count)).to all(eq(0))
  end

  it "leaves another visitor's data alone" do
    other = create(:reservation, product:, quantity: 1)

    visitor.erase!

    expect(Reservation.all).to eq([ other ])
    expect(other.visitor.reload).to be_persisted
    expect(product.reload.stock).to eq(10)
  end

  it "releases a reservation's stock once when the reservation is already gone, as when two deletions race" do
    reservation = create(:reservation, turn:, product:, quantity: 2)
    stale = Visitor.find(visitor.id)
    stale.erase!

    expect { Visitor.new(id: visitor.id).erase! }.not_to raise_error
    expect(product.reload.stock).to eq(12)
    expect(Reservation.exists?(reservation.id)).to be(false)
  end
end
