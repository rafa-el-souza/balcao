require "rails_helper"

RSpec.describe "NFR-02 FR-07 reservation, keyed by the tool_use id" do
  let(:visitor) { create(:visitor) }
  let(:product) { create(:product) }
  let(:pickup_until) { Time.zone.local(2026, 11, 10, 20, 0) }
  let(:attributes) { { visitor:, product:, quantity: 2, pickup_until: } }

  it "creates an open reservation with a short code to read at the counter" do
    reservation = Reservation.create_once!(idempotency_key: "toolu_01A", **attributes)

    expect(reservation).to be_previously_new_record
    expect(reservation).to have_attributes(idempotency_key: "toolu_01A", state: "open", quantity: 2, pickup_until:)
    expect(reservation.code).to match(/\A[#{Reservation::CODE_ALPHABET}]{#{Reservation::CODE_LENGTH}}\z/o)
  end

  it "draws a new code when the one drawn is already taken" do
    taken = create(:reservation, code: "ABCDEF")
    allow(Reservation).to receive(:generate_code).and_return("ABCDEF", "GHJKMN")

    reservation = Reservation.create_once!(idempotency_key: "toolu_01B", **attributes)

    expect(reservation).to be_previously_new_record
    expect(reservation.code).to eq("GHJKMN")
    expect(taken.reload.idempotency_key).not_to eq("toolu_01B")
  end

  it "gives up after a few taken codes rather than loop" do
    create(:reservation, code: "ABCDEF")
    allow(Reservation).to receive(:generate_code).and_return("ABCDEF")

    expect { Reservation.create_once!(idempotency_key: "toolu_01C", **attributes) }
      .to raise_error(ActiveRecord::RecordNotUnique)
    expect(Reservation).to have_received(:generate_code).exactly(Reservation::CODE_ATTEMPTS).times
  end

  it "keeps the code unique in the database" do
    create(:reservation, code: "ABCDEF")
    copy = build(:reservation, code: "ABCDEF")

    expect { Reservation.transaction(requires_new: true) { copy.save!(validate: false) } }
      .to raise_error(ActiveRecord::RecordNotUnique, /"index_reservations_on_code"/)
  end

  it "refuses a quantity below one in the database (SR-16)" do
    reservation = build(:reservation, quantity: 0)

    expect { Reservation.transaction(requires_new: true) { reservation.save!(validate: false) } }
      .to raise_error(ActiveRecord::StatementInvalid, /reservations_quantity_positive/)
  end

  it_behaves_like "an idempotency key", index: "index_reservations_on_idempotency_key" do
    let(:existing) { create(:reservation, idempotency_key: "toolu_REPLAYED", **attributes) }
    let(:duplicate) { build(:reservation, idempotency_key: "toolu_REPLAYED", code: "ZZZZZZ", **attributes) }
    let(:call_again) { -> { Reservation.create_once!(idempotency_key: "toolu_REPLAYED", **attributes) } }
  end
end
