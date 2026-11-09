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
