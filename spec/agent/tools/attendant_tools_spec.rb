require "rails_helper"

# The attendant's tools inside a turn (design §6.3, §6.6): the model asks, the
# SDK's tool runner runs the tool, and the next request carries its result.
RSpec.describe "FR-03 FR-06 FR-07 NFR-02 SR-16 the attendant's tools in a turn" do
  include ModelResponses

  let(:fake) { FakeModel.new(responses) }
  let(:turn) { Turn.for_inbound!(create(:message, body: "tem dipirona?")) }

  def run = AgentRunner.new(client: fake.client, clock: FakeClock.new).run(turn)

  # The tool results the second request sends back to the model.
  def tool_results
    fake.requests.fetch(1).body[:messages].last[:content].select { |block| block[:type] == :tool_result }
  end

  before { CatalogueSeed.seed! }

  context "when the model searches the catalogue" do
    let(:responses) { [ tool_turn(tool_use("search_products", { query: "dipirona" })), reply("[pt] Temos dipirona.") ] }

    it "gives the turn the attendant's tools when no other is named" do
      run

      expect(fake.requests.first.body[:tools].pluck(:name)).to eq(%w[get_store_info search_products create_reservation])
    end

    it "sends the products found back to the model, with their prices" do
      result = run

      expect(tool_results).to contain_exactly(include(is_error: false, content: include("Dipirona gotas 500 mg/ml, 20 ml", "R$ 7,90")))
      expect(result).to have_attributes(outcome: :replied, text: "Temos dipirona.")
      expect(result.tool_calls).to contain_exactly(have_attributes(name: "search_products", input: { "query" => "dipirona" }))
    end
  end

  # NFR-02's scenario: the same turn asks again for the same product, with a
  # new tool_use id, as a turn run again after a model error would.
  context "when the model reserves the same product twice in one turn" do
    let(:product) { Product.find_by!(sku: "dipirona-500mg-10cp") }
    let(:responses) do
      [ tool_turn(tool_use("create_reservation", { product_id: product.id, quantity: 2 })),
        tool_turn(tool_use("create_reservation", { product_id: product.id, quantity: 2 })),
        reply("[pt] Reservado.") ]
    end

    it "keeps one reservation, and the model reads the same code twice" do
      stock = product.stock

      result = run

      reservation = Reservation.sole
      expect(product.reload.stock).to eq(stock - 2)
      expect(result.tool_calls.map(&:output)).to all(include(reservation.code))
      expect(result).to have_attributes(outcome: :replied, text: "Reservado.")
    end
  end

  context "when the model asks for a topic outside the enum" do
    let(:responses) { [ tool_turn(tool_use("get_store_info", { topic: "pet_food" })), reply("[pt] Não sei.") ] }

    it "reaches the tool, which refuses it on the server, and the model reads the refusal (SR-16)" do
      run

      expect(tool_results).to contain_exactly(include(is_error: true, content: match(/no such topic/i)))
    end
  end
end
