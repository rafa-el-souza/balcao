require "rails_helper"

RSpec.describe "NFR-02 FR-07 reservation, keyed by the turn that asked and the product" do
  let(:turn) { create(:turn) }
  let(:visitor) { turn.conversation.visitor }
  let(:product) { create(:product) }
  let(:pickup_until) { Time.zone.local(2026, 11, 10, 20, 0) }
  let(:attributes) { { quantity: 2, pickup_until: } }

  it "creates an open reservation for the turn's visitor, with a short code to read at the counter" do
    reservation = Reservation.create_once!(turn:, product:, **attributes)

    expect(reservation).to be_previously_new_record
    expect(reservation).to have_attributes(turn:, visitor:, product:, state: "open", quantity: 2, pickup_until:)
    expect(reservation.code).to match(/\A[#{Reservation::CODE_ALPHABET}]{#{Reservation::CODE_LENGTH}}\z/o)
  end

  # Review finding C1 of pull request #7: a turn run again after a failure
  # calls the model again, and the API mints a new tool_use id for the same
  # request, so a key made of that id let the retry reserve a second time.
  it "keeps one reservation when the same turn asks again, whatever tool_use id the model sent" do
    first = Reservation.create_once!(turn:, product:, **attributes)

    again = Reservation.create_once!(turn:, product:, **attributes)

    expect(again).to eq(first)
    expect(again).not_to be_previously_new_record
    expect(Reservation.count).to eq(1)
  end

  it "reserves two products asked for in one turn apart" do
    Reservation.create_once!(turn:, product:, **attributes)

    expect(Reservation.create_once!(turn:, product: create(:product), **attributes)).to be_previously_new_record
  end

  it "draws a new code when the one drawn is already taken" do
    taken = create(:reservation, code: "ABCDEF")
    allow(Reservation).to receive(:generate_code).and_return("ABCDEF", "GHJKMN")

    reservation = Reservation.create_once!(turn:, product:, **attributes)

    expect(reservation).to be_previously_new_record
    expect(reservation.code).to eq("GHJKMN")
    expect(taken.reload.turn).not_to eq(turn)
  end

  it "gives up after a few taken codes rather than loop" do
    create(:reservation, code: "ABCDEF")
    allow(Reservation).to receive(:generate_code).and_return("ABCDEF")

    expect { Reservation.create_once!(turn:, product:, **attributes) }
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

  it_behaves_like "an idempotency key", index: "index_reservations_on_turn_id_and_product_id" do
    let(:existing) { create(:reservation, turn:, product:, **attributes) }
    let(:duplicate) { build(:reservation, turn:, product:, code: "ZZZZZZ", **attributes) }
    let(:call_again) { -> { Reservation.create_once!(turn:, product:, **attributes) } }
  end
end
