require "rails_helper"
require Rails.root.join("lib/evals/pipeline").to_s

# A case runs through the app's own turn pipeline (evals/README.md: "Cases
# run through the full turn pipeline ... against a seeded database"): Intake
# stores each message as the web channel does and ProcessTurnJob answers it;
# the runner reads back what the app stored and the visitor got, and leaves
# nothing behind.
RSpec.describe "NFR-08 SR-18 the eval runner's pipeline" do
  include ModelResponses
  include ActiveJob::TestHelper

  let(:responses) { [] }
  let(:fake) { FakeModel.new(responses) }
  let(:pipeline) { Evals::Pipeline.new }
  let(:dipirona) { Product.find_by!(sku: "dipirona-500mg-10cp") }

  # The catalogue is seeded first, so its ids are known to the scripted
  # replies; the pipeline seeds it again by sku, keeping them.
  before do
    CatalogueSeed.seed!
    allow(AgentRunner).to receive(:default_client) { fake.client }
  end

  around { |example| travel_to(Time.zone.local(2026, 11, 13, 10, 0)) { example.run } }

  def kase(*messages, seed: "default", expect: { "language" => "pt" })
    Evals::Case.new(id: "a-case-01", suite: "reservation", lang: "pt", milestone: "MVP", seed:, fast: false,
                    messages:, expect:)
  end

  it "answers each message in turn, the earlier replies live, and reads the last one as the visitor got it" do
    responses.replace([
      tool_turn(tool_use("search_products", { query: "dipirona" })),
      reply("[pt] Temos Dipirona 500 mg, 10 comprimidos, por R$ 7,90."),
      tool_turn(tool_use("search_products", { query: "dipirona comprimido" })),
      tool_turn(tool_use("create_reservation", { product_id: dipirona.id, quantity: 2 })),
      reply("[pt] Pronto, reservei duas caixas.")
    ])

    run = pipeline.run(kase("tem dipirona?", "reserva duas caixas da dipirona em comprimido"))

    expect(run.turns.map(&:message)).to eq([ "tem dipirona?", "reserva duas caixas da dipirona em comprimido" ])
    expect(run.turns.first).to have_attributes(outcome: "replied", notice: FixedReply.notice("pt-BR"))
    expect(run.turns.first.reply).to start_with(FixedReply.notice("pt-BR")).and end_with("por R$ 7,90.")
    observation = run.observation
    expect(observation.notice).to be_nil
    expect(observation.reply).to start_with("Pronto, reservei duas caixas.")
    expect(observation.reply).to match(/Reserva [A-Z0-9-]+: 2 × Dipirona 500 mg, 10 comprimidos, retirada até 14\/11 às 14:00\./)
    expect(observation.tool_calls.map(&:name)).to eq(%w[search_products create_reservation])
    expect(observation.tool_calls.last.input).to eq("product_id" => dipirona.id, "quantity" => 2)
    expect(observation.reservation_created).to be(true)
  end

  it "keeps each turn's model calls and tool calls, with their usage, for the results file" do
    responses.replace([ tool_turn(tool_use("search_products", { query: "dipirona" })), reply("[pt] Temos, por R$ 7,90.") ])

    turn = pipeline.run(kase("tem dipirona?")).turns.sole

    expect(turn.model_calls.map(&:model)).to eq(%w[claude-opus-5-5 claude-opus-5-5])
    expect(turn.model_calls.first).to have_attributes(stop_reason: "tool_use", output_tokens: 80, cache_read_tokens: 3000)
    expect(turn.tool_calls.sole).to have_attributes(name: "search_products", input: { "query" => "dipirona" },
                                                    output: include("Dipirona"), refusal: nil, failed: false)
    expect(turn.latency_ms).to be >= 0
  end

  it "leaves no row of the attempt behind, and starts each from the case's seed alone" do
    responses.replace([ tool_turn(tool_use("create_reservation", { product_id: dipirona.id, quantity: 2 })), reply("[pt] Reservado.") ] * 2)
    stock = dipirona.stock

    2.times { expect(pipeline.run(kase("reserva duas caixas da dipirona em comprimido")).observation.reservation_created).to be(true) }

    expect([ Visitor.count, Conversation.count, Message.count, Turn.count, TraceEvent.count, Reservation.count ]).to all(eq(0))
    expect(dipirona.reload.stock).to eq(stock)
  end

  it "applies the case's seed overlay to the tools the model calls, inside the attempt only" do
    ibuprofeno = Product.find_by!(sku: "ibuprofeno-400mg-10caps")
    responses.replace([ tool_turn(tool_use("search_products", { query: "ibuprofeno" })), reply("[es] Está agotado.") ])

    run = pipeline.run(kase("quiero reservar ibuprofeno", seed: "out_of_stock_ibuprofen"))

    expect(run.observation.tool_calls.sole.output).to include("\"stock\":0")
    expect(ibuprofeno.reload.stock).to be_positive
  end

  describe "the commands (FR-04, FR-05)" do
    it "reads a reset from the conversations: the case's closed, a new one open" do
      responses.replace([ reply("[pt] Temos, por R$ 7,90.") ])

      observation = pipeline.run(kase("tem dipirona?", "/reiniciar")).observation

      expect(observation.conversation_reset).to be(true)
      expect(observation.reply).to eq(FixedReply.with_notice(FixedReply.command(:reset, "pt-BR"), "pt-BR"))
      expect(observation.notice).to eq(FixedReply.notice("pt-BR"))
    end

    # Review finding C2 of pull request #20: the web channel identifies the
    # visitor on every message, so one who deleted their data starts over.
    it "starts over a visitor who writes after deleting their data, as the web channel does" do
      responses.replace([ reply("[pt] Olá! Em que posso ajudar?") ])

      observation = pipeline.run(kase("apagar meus dados", "oi")).observation

      expect(observation.reply).to eq(FixedReply.with_notice("Olá! Em que posso ajudar?", "pt-BR"))
      expect(observation.data_deleted).to be(false)
    end

    it "sends a message as the web channel stores it, without a NUL or the spaces around it" do
      responses.replace([ reply("[pt] Temos, por R$ 7,90.") ])

      pipeline.run(kase("  tem dipirona?\u0000  "))

      expect(fake.requests.sole.body[:messages].last[:content].last).to eq(type: "text", text: "tem dipirona?")
    end

    it "reads a deletion's confirmation from the stream, since no conversation is left to store it" do
      run = pipeline.run(kase("apagar meus dados"))

      expect(run.observation).to have_attributes(data_deleted: true, reply: FixedReply.command(:delete, "pt-BR"), tool_calls: [])
      expect(run.turns.sole.outcome).to eq("deleted")
      expect(fake.requests).to be_empty
    end
  end

  it "reads the outcome of a turn the model could not answer, with the error's class" do
    responses.replace([ error(:overloaded) ] * 3)

    turn = pipeline.run(kase("tem dipirona?")).turns.sole

    expect(turn).to have_attributes(outcome: "model_error", error_type: "Anthropic::Errors::OverloadedError")
    expect(turn.reply).to end_with(FixedReply.fallback("pt-BR"))
  end
end
