require "rails_helper"

RSpec.describe "NFR-02 FR-19 visitor, one row per identity and channel" do
  let(:identity_hash) { Digest::SHA256.hexdigest("pepper" + "bsuid") }

  it "creates the visitor on first contact" do
    visitor = Visitor.identify!(channel: "whatsapp", identity_hash:)

    expect(visitor).to be_previously_new_record
    expect(visitor).to have_attributes(channel: "whatsapp", identity_hash:)
  end

  it "returns the visitor already known, by the read alone" do
    known = create(:visitor, channel: "whatsapp", identity_hash:)

    result, raised = with_raised_exceptions { Visitor.identify!(channel: "whatsapp", identity_hash:) }

    expect(result).to eq(known)
    expect(raised).not_to include(ActiveRecord::RecordNotUnique)
  end

  it "keeps the same hash on two channels apart" do
    create(:visitor, channel: "web", identity_hash:)

    expect(Visitor.identify!(channel: "whatsapp", identity_hash:)).to be_previously_new_record
  end

  it_behaves_like "an idempotency key", index: "index_visitors_on_channel_and_identity_hash" do
    let(:existing) { create(:visitor, channel: "whatsapp", identity_hash:) }
    let(:duplicate) { build(:visitor, channel: "whatsapp", identity_hash:) }
    let(:call_again) do
      lambda do
        # The read ran before another writer committed the same person's row.
        allow(Visitor).to receive(:find_by).and_return(nil)
        Visitor.identify!(channel: "whatsapp", identity_hash:)
      end
    end
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
    identity_hash = Digest::SHA256.hexdigest("pepper" + "bsuid-r1")
    visitor = travel_to(Time.zone.local(2026, 11, 2, 10, 0)) { Visitor.identify!(channel: "whatsapp", identity_hash:) }
    travel_to(Time.zone.local(2026, 11, 9, 18, 0)) { Visitor.identify!(channel: "whatsapp", identity_hash:) }

    travel_to(Time.zone.local(2026, 11, 10, 3, 0)) do
      expect(Visitor.unseen_for(7.days)).not_to include(visitor)
    end
    expect(visitor.reload.last_seen_at).to eq(Time.zone.local(2026, 11, 9, 18, 0))
  end
end
