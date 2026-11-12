require "rails_helper"

RSpec.describe "FR-03 SR-16 get_store_info, the store sheet's topics" do
  let(:turn) { create(:turn) }
  let(:calls) { [] }
  let(:tool) { Tools::GetStoreInfo.new(turn:, on_call: ->(call) { calls << call }) }

  # The input as the SDK's runner hands it over: the model's JSON, with symbol
  # keys, coerced through the tool's schema, which keeps a value outside the
  # enum as it came.
  def input(topic) = Anthropic::Internal::Type::Converter.coerce(tool, { topic: })

  def ask(topic) = JSON.parse(tool.call(input(topic)))

  it "is sent strict, with the five topics of the store sheet as its only choices" do
    request = { tools: [ tool ] }
    Anthropic::Helpers::Messages.distill_input_schema_models!(request, strict: nil)

    expect(request[:tools].first.to_h).to include(
      name: "get_store_info", strict: true,
      input_schema: include(required: [ "topic" ], properties: { topic: include(type: "string", enum: StoreSheet::TOPICS) })
    )
  end

  it "answers a topic with what config/store.yml says of it" do
    delivery = ask("delivery")

    expect(delivery).to include("topic" => "delivery")
    expect(delivery.fetch("areas")).to include(include("name" => "Santa Tereza", "fee" => "R$ 7,00"))
  end

  it "answers each of the five topics" do
    StoreSheet::TOPICS.each { |topic| expect(ask(topic)).to eq({ "topic" => topic }.merge(StoreSheet.current.topic(topic))) }
  end

  # The glass box writes "4 bairros" under a list and nothing under a single
  # fact (design §10, note of 2026-11-12, FR-12): the call it reports says
  # what the topic lists and how many, from the result before any cut.
  it "reports what a topic that is a list lists and how many, and nothing for a single fact" do
    sheet = StoreSheet.current
    { "delivery" => [ "areas", sheet.topic("delivery")["areas"].size ],
      "payment" => [ "methods", sheet.topic("payment")["methods"].size ],
      "services" => [ "services", sheet.topic("services")["list"].size ] }.each do |topic, (unit, count)|
      ask(topic)
      expect(calls.last).to have_attributes(unit:, count:), topic
    end
    %w[contact parking].each do |topic|
      ask(topic)
      expect(calls.last).to have_attributes(unit: nil, count: nil), topic
    end
    expect(calls.map(&:characters)).to eq(calls.map { |call| call.output.length })
  end

  it "answers from the sheet the process loaded, so an edit of the file is the new fact (FR-26)" do
    sheet = StoreSheet.new(YAML.safe_load_file(StoreSheet::PATH).deep_merge("topics" => { "parking" => { "text" => "Sem vagas." } }))
    allow(StoreSheet).to receive(:current).and_return(sheet)

    expect(ask("parking")).to eq("topic" => "parking", "text" => "Sem vagas.")
  end

  it "re-checks the topic on the server and tells the model what to do with an unknown one (SR-16)" do
    expect { tool.call(input("pet_food")) }
      .to raise_error(AgentTool::Error, /no such topic.*delivery, payment, services, contact, parking.*hours.*do not know/i)
    expect(calls.first).to have_attributes(name: "get_store_info", input: { "topic" => "pet_food" }, is_error: true)
  end
end
