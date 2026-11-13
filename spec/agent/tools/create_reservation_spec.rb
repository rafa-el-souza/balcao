require "rails_helper"

RSpec.describe "FR-07 NFR-02 SR-16 create_reservation, units held for pickup at the counter" do
  let(:visitor) { create(:visitor) }
  let(:conversation) { create(:conversation, visitor:) }
  let(:turn) { create(:turn, inbound_message: create(:message, conversation:)) }
  let(:product) { create(:product, name: "Dipirona 500 mg, 10 comprimidos", stock: 40) }
  let(:calls) { [] }

  # A Thursday at noon in São Paulo: the pickup deadline is Friday's closing.
  around { |example| travel_to(Time.zone.local(2026, 11, 12, 12, 4)) { example.run } }

  def tool(for_turn = turn) = Tools::CreateReservation.new(turn: for_turn, on_call: ->(call) { calls << call })

  # The input as the SDK's runner hands it over (see search_products_spec).
  def reserve(for_turn = turn, **input)
    input = { product_id: product.id, quantity: 2 }.merge(input)
    used = tool(for_turn)
    JSON.parse(used.call(Anthropic::Internal::Type::Converter.coerce(used, input)))
  end

  # The refusal the model reads, with its reason code.
  def refusal(for_turn = turn, **)
    reserve(for_turn, **)
    raise "the tool did not refuse"
  rescue AgentTool::Error => e
    e
  end

  def another_turn = create(:turn, inbound_message: create(:message, conversation:))

  def open_reservation(**attributes)
    create(:reservation, turn: another_turn, visitor:, product: create(:product), **attributes)
  end

  it "is sent strict, with the product's id and the quantity both required" do
    request = { tools: [ tool ] }
    Anthropic::Helpers::Messages.distill_input_schema_models!(request, strict: nil)

    expect(request[:tools].first.to_h).to include(
      name: "create_reservation", strict: true,
      input_schema: include(required: %w[product_id quantity],
                            properties: include(product_id: include(type: "string"), quantity: include(type: "integer")))
    )
  end

  # Review finding C2 of pull request #19: the prompt has times written as the
  # tools write them, and pickup_until is a timestamp.
  it "tells the model to write the deadline as a day and a time, never as the timestamp" do
    expect(Tools::CreateReservation.doc_string).to include("a day and a time", "never as the timestamp")
  end

  it "tells the model to reserve only what was asked, never a prescription product, and to give the code and the deadline" do
    expect(Tools::CreateReservation.doc_string).to include("search_products", "prescription", "code", "pickup_until",
                                                          "#{Tools::CreateReservation::MAX_QUANTITY} units",
                                                          "#{Tools::CreateReservation::MAX_OPEN} open reservations")
  end

  it "holds the units for the turn's visitor, takes them from stock, and answers with the code, the units and the deadline" do
    result = reserve(quantity: 2)

    reservation = Reservation.sole
    expect(reservation).to have_attributes(turn:, visitor:, product:, quantity: 2, state: "open",
                                           pickup_until: Time.zone.local(2026, 11, 13, 20, 0))
    expect(product.reload.stock).to eq(38)
    expect(result).to eq("code" => reservation.code, "quantity" => 2, "product" => "Dipirona 500 mg, 10 comprimidos",
                         "pickup_until" => "2026-11-13T20:00:00-03:00")
    expect(calls.sole).to have_attributes(name: "create_reservation", is_error: false, refusal: nil)
  end

  # NFR-02's scenario: a turn run again calls the model again, which asks with
  # a new tool_use id and maybe another quantity; the turn and the product
  # are the key.
  it "keeps one reservation and takes the stock once when the same turn asks again for the same product" do
    first = reserve(quantity: 2)

    again = reserve(quantity: 3)

    expect(again).to eq(first)
    expect(Reservation.count).to eq(1)
    expect(product.reload.stock).to eq(38)
  end

  # Review finding RN2 of pull request #7: a check made before the lookup
  # would refuse a turn run again because of its own first reservation.
  it "finds the turn's own reservation before any check, so the stock it took or the cap it filled never refuses it" do
    product.update!(stock: 2)
    2.times { open_reservation }
    first = reserve(quantity: 2)

    expect(product.reload.stock).to eq(0)
    expect(reserve(quantity: 2)).to eq(first)
  end

  it "reserves a second product in the same turn apart" do
    reserve
    reserve(product_id: create(:product).id)

    expect(turn.reservations.count).to eq(2)
  end

  describe "the refusals, each with its reason code for the glass box (FR-12)" do
    def nothing_reserved
      expect(turn.reservations).to be_empty
      expect(product.reload.stock).to eq(40)
    end

    # FR-07, as the owner read it on 2026-11-13: the search gives the price
    # and the flag, and the reservation is not made; called anyway, the tool
    # refuses it.
    it "refuses a product that requires a prescription, sold only against it at the counter" do
      product.update!(prescription_required: true)

      error = refusal

      expect(error).to have_attributes(reason: "prescription", message: match(/prescription.*counter/))
      nothing_reserved
    end

    it "refuses more than #{Tools::CreateReservation::MAX_QUANTITY} units, offering ten or the pharmacist" do
      error = refusal(quantity: 11)

      expect(error).to have_attributes(reason: "over_limit", message: match(/limit of 10 units.*Offer 10 units.*pharmacist/))
      nothing_reserved
      expect(reserve(quantity: 10)).to include("quantity" => 10)
    end

    # Review finding C3 of pull request #19: the limit's refusal offered ten
    # units before the stock and the cap were read, so the alternative it
    # offered could not be had.
    it "offers, past the limit, only units the stock holds" do
      product.update!(stock: 3)

      error = refusal(quantity: 11)

      expect(error).to have_attributes(reason: "low_stock", message: match(/Only 3 units.*Offer 3 units/))
      expect(error.message).not_to include("Offer 10 units")
    end

    it "offers ten past the limit, and no more, when the stock holds more" do
      error = refusal(quantity: 500)

      expect(error).to have_attributes(reason: "over_limit", message: match(/Offer 10 units/))
      expect(error.message).not_to include("40 units")
    end

    it "refuses past the limit at the cap of open reservations for the cap, offering no units" do
      3.times { open_reservation }

      error = refusal(quantity: 11)

      expect(error).to have_attributes(reason: "open_limit")
      expect(error.message).not_to include("Offer 10 units")
    end

    it "refuses past the limit a product out of stock as out of stock" do
      product.update!(stock: 0)

      expect(refusal(quantity: 15)).to have_attributes(reason: "out_of_stock")
    end

    it "refuses a quantity below one, or one that is not a whole number (SR-16)" do
      [ 0, -2, 2.5, "2", nil ].each do |quantity|
        expect(refusal(quantity:)).to have_attributes(reason: "invalid_quantity"), quantity.inspect
      end
      nothing_reserved
    end

    it "refuses an id that no listed product holds, or that is not an id (SR-16)" do
      unlisted = create(:product, listed: false)

      [ SecureRandom.uuid, "dipirona", unlisted.id, nil ].each do |product_id|
        expect(refusal(product_id:)).to have_attributes(reason: "unknown_product", message: match(/search_products/)),
                                        product_id.inspect
      end
      nothing_reserved
    end

    # The system lists the three under the reply (TurnProcessor), so the
    # refusal carries none of them: a reservation of another conversation
    # never enters this one's trace (review findings C5 and N1 of pull
    # request #19; FR-12).
    it "refuses a fourth open reservation, leaving the list of the three to the system" do
      held = Array.new(3) { open_reservation }

      error = refusal

      expect(error).to have_attributes(reason: "open_limit", message: match(/3 open reservations.*listed after your reply/))
      held.each { |reservation| expect(error.message).not_to include(reservation.code) }
      nothing_reserved
    end

    it "counts only the reservations still open and within their pickup deadline" do
      open_reservation(state: "expired")
      open_reservation(state: "cancelled")
      open_reservation(pickup_until: 1.minute.ago)

      expect(reserve).to include("quantity" => 2)
    end

    it "counts another visitor's reservations apart" do
      3.times { create(:reservation) }

      expect(reserve).to include("quantity" => 2)
    end

    it "refuses more units than the stock holds, offering what there is" do
      product.update!(stock: 3)

      error = refusal(quantity: 5)

      expect(error).to have_attributes(reason: "low_stock", message: match(/Only 3 units.*Offer 3 units/))
      expect(Reservation.count).to eq(0)
      expect(product.reload.stock).to eq(3)
    end

    it "refuses a product out of stock" do
      product.update!(stock: 0)

      expect(refusal).to have_attributes(reason: "out_of_stock", message: match(/out of stock.*pharmacist/))
      expect(Reservation.count).to eq(0)
    end

    it "reports the refusal with its reason, for the trace" do
      refusal(quantity: 11)

      expect(calls.sole).to have_attributes(name: "create_reservation", is_error: true, refusal: "over_limit")
    end
  end

  # The stock the seed writes is the seed's less what open reservations hold,
  # which holds for a reservation still in flight only when it takes its
  # units by a relative decrement in its own transaction (design §10, review
  # finding C4 of pull request #8; FR-15).
  describe "the stock, taken in the reservation's own transaction" do
    # The stock as another writer leaves it after the tool read the product.
    def stock_written_meanwhile(stock)
      allow(Product).to receive(:find_by).and_wrap_original do |original, *arguments, **options|
        original.call(*arguments, **options).tap { Product.where(id: product.id).update_all(stock:) }
      end
    end

    it "takes the units from the stock as it is, not as the tool read it" do
      stock_written_meanwhile(7)

      reserve(quantity: 2)

      expect(product.reload.stock).to eq(5)
    end

    it "refuses on the stock as the reservation's transaction reads it, not as the tool first read it" do
      stock_written_meanwhile(1)

      error = refusal(quantity: 2)

      expect(error).to have_attributes(reason: "low_stock", message: match(/Only 1 unit\b/))
      expect(Reservation.count).to eq(0)
      expect(product.reload.stock).to eq(1)
    end

    # Another writer between the check and the decrement: the decrement
    # never goes below zero, and the reservation goes back with it.
    it "keeps nothing when the units are gone by the decrement" do
      product.update!(stock: 1)
      used = tool
      allow(used).to receive(:stock_of).and_return(40, 1)

      error = begin
        used.call(Anthropic::Internal::Type::Converter.coerce(used, { product_id: product.id, quantity: 2 }))
      rescue AgentTool::Error => e
        e
      end

      expect(error).to have_attributes(reason: "low_stock", message: match(/Only 1 unit\b/))
      expect(Reservation.count).to eq(0)
      expect(product.reload.stock).to eq(1)
    end
  end
end
