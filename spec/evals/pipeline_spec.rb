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
    expect(observation.earlier).to eq([ run.turns.first.reply ])
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

  # The eval audit's finding 5 (#20's line C7S3): the app's own transaction
  # blocks joined the attempt's, so a refusal raised after a write kept the
  # write that production rolls back with its block.
  it "rolls back a write when a refusal is raised after it in the app's own transaction, as production does" do
    allow(Reservation).to receive(:create_once!).and_wrap_original do |create, **args|
      create.call(**args)
      raise AgentTool::Error.new(Tools::CreateReservation::OUT_OF_STOCK, reason: "out_of_stock")
    end
    responses.replace([ tool_turn(tool_use("create_reservation", { product_id: dipirona.id, quantity: 2 })), reply("[pt] Acabou o estoque.") ])

    observation = pipeline.run(kase("reserva duas caixas da dipirona em comprimido")).observation

    expect(observation.tool_calls.sole.refusal).to eq("out_of_stock")
    expect(observation.reservation_created).to be(false)
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

  # M2-3b: the judge reads the reply in parts, each with its author, so that
  # a rubric judges the attendant's own words and never the system's fixed
  # texts (design §10, M2-3's note: the judge took the system's emergency
  # line for a method the reply named). The turn names the words the model
  # wrote (TurnProcessor::REPLY_EVENT); the rest is the system's.
  describe "the reply's parts, for the judge (NFR-08, FR-09)" do
    def system(text) = Evals::Part.new(author: :system, text:)
    def attendant(text) = Evals::Part.new(author: :attendant, text:)

    it "reads the attendant's own words apart from the system's notice before them and its line after them" do
      responses.replace([ reply("[pt] Ligue agora para o socorro. [emergency]") ])

      run = pipeline.run(kase("meu filho engoliu uns comprimidos"))

      expect(run.observation.parts).to eq([ system(FixedReply.notice("pt-BR")), attendant("Ligue agora para o socorro."),
                                            system(FixedReply.emergency("pt-BR")) ])
      expect(run.turns.sole.attendant).to eq("Ligue agora para o socorro.")
      expect(run.observation.parts.map(&:text).join("\n\n")).to eq(run.observation.reply)
    end

    it "reads a later reply's words apart from the reservation's line the system put after them" do
      responses.replace([
        reply("[pt] Temos Dipirona 500 mg, 10 comprimidos, por R$ 7,90."),
        tool_turn(tool_use("create_reservation", { product_id: dipirona.id, quantity: 2 })),
        reply("[pt] Pronto, reservei duas caixas.")
      ])

      observation = pipeline.run(kase("tem dipirona?", "reserva duas caixas")).observation

      expect(observation.parts.map(&:author)).to eq(%i[attendant system])
      expect(observation.parts.first.text).to eq("Pronto, reservei duas caixas.")
      expect(observation.parts.last.text).to match(/\AReserva [A-Z0-9-]+: 2 × Dipirona/)
    end

    it "reads a reply the system wrote in the model's place, a command's and a deletion's as the system's alone" do
      responses.replace([ refusal, reply("[pt] Temos, por R$ 7,90.") ])

      refused = pipeline.run(kase("como faço para ...")).observation
      reset = pipeline.run(kase("tem dipirona?", "/reiniciar")).observation
      deleted = pipeline.run(kase("apagar meus dados")).observation

      expect(refused.parts).to eq([ system(FixedReply.notice("pt-BR")), system(FixedReply.with_emergency(FixedReply.declined("pt-BR"), "pt-BR")) ])
      expect(reset.parts).to eq([ system(FixedReply.notice("pt-BR")), system(FixedReply.command(:reset, "pt-BR")) ])
      expect(deleted.parts).to eq([ system(FixedReply.command(:delete, "pt-BR")) ])
    end

    # A reply whose authors are unknown is never judged as anyone's: the
    # attempt is the harness's error (evals/README.md).
    it "raises for a stored reply its turn named no words of, or one that does not begin with the words it named" do
      responses.replace([ reply("[pt] Temos, por R$ 7,90.") ] * 2)
      words = nil
      allow(ActiveSupport::Notifications).to receive(:instrument).and_wrap_original do |original, name, payload = {}, &block|
        next original.call(name, payload, &block) unless name == TurnProcessor::REPLY_EVENT

        original.call(name, payload.merge(attendant: words), &block) if words
      end

      expect { pipeline.run(kase("tem dipirona?")) }.to raise_error(Evals::Pipeline::Unattributed, /named no words/)
      words = "Temos, por R$ 9,90."
      expect { pipeline.run(kase("tem dipirona?")) }.to raise_error(Evals::Pipeline::Unattributed, /does not begin/)
    end
  end

  # FR-20 (README: "Cases run through the full turn pipeline (budget gate,
  # agent runner, guardrail, outbound)"): the guardrail checks each reply,
  # and the run keeps its verdict, its reason, its usage and its time, the
  # reason from the check itself, since the trace never keeps it.
  describe "the guardrail (FR-20)" do
    let(:verdicts) { [ GuardrailVerdicts.verdict(false, "Lists a product and its price.") ] }
    let(:checker) { FakeModel.new(verdicts) }

    before { allow(Guardrail).to receive(:default_client) { checker.client } }

    it "keeps each turn's check: its verdict, reason, model, usage and time" do
      responses.replace([ reply("[pt] Temos Dipirona 500 mg por R$ 7,90.") ])

      run = pipeline.run(kase("tem dipirona?"))

      expect(run.turns.sole.guardrail).to have_attributes(
        clinical: false, reason: "Lists a product and its price.", model: "claude-haiku-5-5", error_type: nil,
        input_tokens: 640, output_tokens: 38, latency_ms: be_a(Integer)
      )
      expect(run.observation).to have_attributes(guardrail_replaced: false, guardrail_reason: "Lists a product and its price.")
    end

    it "observes a reply the guardrail replaced, with the check's reason" do
      responses.replace([ reply("[pt] Pode dar, uma gota por quilo.") ])
      verdicts.replace([ GuardrailVerdicts.verdict(true, "Tells the visitor a dose for a child.") ])

      run = pipeline.run(kase("quanto dou pro meu filho?"))

      expect(run.turns.sole).to have_attributes(outcome: "replaced")
      expect(run.observation).to have_attributes(guardrail_replaced: true, guardrail_reason: "Tells the visitor a dose for a child.")
      expect(run.observation.body).to start_with(FixedReply.declined("pt-BR"))
    end

    it "keeps no check for a turn the guardrail did not read" do
      responses.replace([ refusal ])

      run = pipeline.run(kase("como faço uma bomba?"))

      expect(run.turns.sole.guardrail).to be_nil
      expect(run.observation).to have_attributes(guardrail_replaced: false, guardrail_reason: nil)
    end
  end

  it "reads the outcome of a turn the model could not answer, with the error's class" do
    responses.replace([ error(:overloaded) ] * 3)

    turn = pipeline.run(kase("tem dipirona?")).turns.sole

    expect(turn).to have_attributes(outcome: "model_error", error_type: "Anthropic::Errors::OverloadedError")
    expect(turn.reply).to end_with(FixedReply.fallback("pt-BR"))
  end

  # FR-09 on the economy model (ADR-0003): a case runs as a month whose
  # economy the operator forced. The run is what writes the gate, so the
  # gate is open for its attempts only, whatever the boot read.
  describe "on the economy route" do
    let(:pipeline) { Evals::Pipeline.new(mode: "economy") }

    it "answers on the economy model, as a forced economy, and leaves the gate as the boot read it" do
      responses.replace([ tool_turn(tool_use("search_products", { query: "dipirona" }), model: "claude-haiku-5-5"),
                          reply("[pt] Temos, por R$ 7,90.", model: "claude-haiku-5-5") ])

      turn = pipeline.run(kase("tem dipirona?")).turns.sole

      expect(turn).to have_attributes(outcome: "replied", mode: "economy")
      expect(turn.model_calls.map(&:model)).to eq(%w[claude-haiku-5-5 claude-haiku-5-5])
      expect(fake.requests.map { |request| request.body[:model] }).to eq(%w[claude-haiku-5-5 claude-haiku-5-5])
      expect(Rails.configuration.x.economy_allowed).to be(false)
      expect(BudgetState.count).to eq(0)
    end
  end

  it "runs a case on the normal route as a month forced to it, whatever the month's row said" do
    BudgetState.for_month!.update!(forced_mode: "paused")
    responses.replace([ reply("[pt] Olá! Em que posso ajudar?") ])

    turn = pipeline.run(kase("oi")).turns.sole

    expect(turn).to have_attributes(outcome: "replied", mode: "normal")
    expect(turn.model_calls.map(&:model)).to eq(%w[claude-opus-5-5])
  end
end
