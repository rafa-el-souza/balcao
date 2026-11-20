require "rails_helper"

# FR-20 (threat model SR-18, R4): the reply the model wrote passes the
# guardrail's check before it is sent. A clinical verdict replaces the text
# with FR-09's decline and the offer of the pharmacist (or the emergency line
# the reply asked for), keeping the facts the turn's tools produced as fixed
# lines; no verdict sends the reply as written, traced (fail-open). The check
# is part of the turn: its span is the trace's (FR-12), its usage the ledger's
# (FR-14), and a turn whose reply is stored is never checked again (NFR-02).
RSpec.describe "FR-20 SR-18 the guardrail in a turn (FR-09, FR-12, FR-14, NFR-02)" do
  include ModelResponses
  include ActiveJob::TestHelper

  let(:visitor) { create(:visitor) }
  let(:conversation) { create(:conversation, visitor:) }
  let(:responses) { [ reply("[pt] Temos Dipirona 500 mg por R$ 7,90, em estoque.") ] }
  let(:fake) { FakeModel.new(responses) }
  let(:verdicts) { [ GuardrailVerdicts.verdict(false, "Lists a product and its price.") ] }
  let(:checker) { FakeModel.new(verdicts) }

  before do
    allow(AgentRunner).to receive(:default_client) { fake.client }
    allow(Guardrail).to receive(:default_client) { checker.client }
  end

  def inbound(text, conversation: self.conversation)
    message = Message.record_inbound!(conversation:, external_id: SecureRandom.uuid, body: text)
    Turn.for_inbound!(message)
  end

  def perform(turn) = ProcessTurnJob.perform_now(turn.id)

  def spans(turn) = TraceEvent.where(turn_id: turn.id).order(:started_at, :created_at)

  def root(turn) = spans(turn).where(name: "balcao.turn").last

  def check(turn) = spans(turn).find_by(name: "balcao.guardrail")

  def clinical(reason = "Gives clinical advice.") = verdicts.replace([ GuardrailVerdicts.verdict(true, reason) ])

  def body(text, language = "pt-BR") = FixedReply.with_notice(text, language)

  describe "a reply the check passes" do
    it "is sent as the model wrote it, after the check read it beside the visitor's message" do
      turn = inbound("tem dipirona?")

      perform(turn)

      expect(turn.outbound_message.body).to eq(body("Temos Dipirona 500 mg por R$ 7,90, em estoque."))
      expect(checker.requests.sole.body.fetch(:messages).sole.fetch(:content))
        .to eq("<visitor_message>\ntem dipirona?\n</visitor_message>\n\n<reply>\nTemos Dipirona 500 mg por R$ 7,90, em estoque.\n</reply>")
      expect(turn.reload.state).to eq("replied")
      expect(root(turn).span_attributes).to include("balcao.turn.outcome" => "replied")
    end

    it "leaves the check's span in the trace, under the turn, with its verdict, model, usage, cost and time" do
      turn = inbound("tem dipirona?")

      perform(turn)

      span = check(turn)
      expect(span.parent_span_id).to eq(root(turn).span_id)
      expect(span.finished_at).to be_present
      expect(span.span_attributes).to include(
        "gen_ai.operation.name" => "chat", "gen_ai.provider.name" => "anthropic", "gen_ai.request.model" => "claude-haiku-5-5",
        "gen_ai.request.reasoning.level" => ModelPolicy.guardrail.effort, "gen_ai.response.model" => "claude-haiku-5-5",
        "anthropic.message.stop_reason" => "end_turn", "gen_ai.usage.input_tokens" => 640, "gen_ai.usage.output_tokens" => 38,
        "balcao.cost.usd" => be_positive, "balcao.latency_ms" => be_a(Integer), "balcao.guardrail.clinical" => false
      )
      expect(span.span_attributes).not_to have_key("error.type")
    end

    # The reason may restate the advice it found, so the trace, which the
    # visitor and anyone holding the link read, never keeps it.
    it "keeps the check's reason out of the trace" do
      turn = inbound("tem dipirona?")

      perform(turn)

      expect(spans(turn).flat_map { |span| span.span_attributes.values }.join(" ")).not_to include("Lists a product and its price.")
    end

    it "charges the check to the month, as a second usage record of the turn" do
      turn = inbound("tem dipirona?")

      perform(turn)

      records = UsageRecord.where(turn_id: turn.id).order(:created_at)
      expect(records.map(&:model)).to eq(%w[claude-opus-5-5 claude-haiku-5-5])
      expect(records.last).to have_attributes(input_tokens: 640, output_tokens: 38, cost_usd: be_positive)
      expect(BudgetState.for_month!.spent_usd).to eq(records.sum(&:cost_usd))
    end
  end

  describe "a reply the check finds clinical" do
    it "is replaced with FR-09's decline and the offer, in the reply's language, and the trace says it was replaced" do
      responses.replace([ reply("[es] Sí, puedes, pero no más de una cerveza.") ])
      clinical("Tells the visitor ibuprofen with beer is fine.")
      turn = inbound("¿puedo tomar ibuprofeno con alcohol?")

      perform(turn)

      expect(turn.outbound_message.body).to eq(body(FixedReply.with_offer(FixedReply.declined("es"), "es"), "es"))
      expect(turn.reload.state).to eq("replied")
      expect(root(turn).span_attributes).to include("balcao.turn.outcome" => "replaced")
      expect(check(turn).span_attributes).to include("balcao.guardrail.clinical" => true)
    end

    # FR-09: the emergency line comes alone, in every reply that asks for it.
    # A replaced emergency reply opened with the decline, "quem responde é o
    # farmacêutico da loja", before the line, where the model had urged the
    # call (#59's M1; the owner, 2026-11-20, "Sim, a proxima fatia leva os
    # consertos"): it opens with the call now, and names no pharmacist.
    it "opens a replaced emergency reply with the call, then the emergency line, and never with the decline" do
      responses.replace([ reply("[pt] Dê bastante água e espere passar. [emergency]") ])
      clinical
      turn = inbound("meu filho engoliu uns comprimidos")

      perform(turn)

      expect(turn.outbound_message.body).to eq(body(FixedReply.with_emergency(FixedReply.call_now("pt-BR"), "pt-BR")))
      expect(turn.outbound_message.body).not_to include(FixedReply.declined("pt-BR"))
    end

    { "en" => "my son swallowed some pills", "es" => "mi hijo se tragó unas pastillas" }.each do |language, message|
      it "opens it with the call in the reply's language, #{language}" do
        responses.replace([ reply("[#{language}] Give him water and wait. [emergency]") ])
        clinical
        turn = inbound(message)

        perform(turn)

        expect(turn.outbound_message.body).to eq(body(FixedReply.with_emergency(FixedReply.call_now(language), language), language))
      end
    end

    # The emergency line comes alone: a product's price is not what the
    # visitor needs then, even one the message names.
    it "lists no product under a replaced emergency reply, and keeps the reservation the turn stored" do
      product = create(:product, name: "Paracetamol 750 mg, 20 comprimidos", active_ingredient: "paracetamol", stock: 10)
      responses.replace([ tool_turn(tool_use("search_products", { query: "paracetamol" })),
                          tool_turn(tool_use("create_reservation", { product_id: product.id, quantity: 1 })),
                          reply("[pt] Oito de 750 mg pode passar do limite; ligue agora. [emergency]") ])
      clinical
      turn = inbound("tomei 8 paracetamol, reserva mais uma caixa? é perigoso?")

      perform(turn)

      expect(turn.outbound_message.body)
        .to eq(body(FixedReply.with_reservations(FixedReply.with_emergency(FixedReply.call_now("pt-BR"), "pt-BR"),
                                                 turn.reservations.to_a, "pt-BR")))
    end

    # FR-10's MVP note: a reply that follows one carrying the offer in the
    # same language leaves it out.
    it "leaves the offer out after a reply that carried it, as any reply does" do
      earlier = inbound("oi")
      responses.replace([ reply("[pt] Isso é com o farmacêutico. [pharmacist]"), reply("[pt] Pode sim.") ])
      verdicts.replace([ GuardrailVerdicts.verdict(false), GuardrailVerdicts.verdict(true) ])
      perform(earlier)
      turn = inbound("posso dar pro meu filho?")

      perform(turn)

      expect(turn.outbound_message.body).to eq(FixedReply.declined("pt-BR"))
    end

    it "keeps the products the turn found, with their prices, stock and prescription flag, as fixed lines" do
      create(:product, name: "Dipirona 500 mg, 10 comprimidos", active_ingredient: "dipirona", price: BigDecimal("7.90"), stock: 12)
      create(:product, name: "Dipirona gotas 20 ml", active_ingredient: "dipirona", price: BigDecimal("9.50"), stock: 0)
      responses.replace([ tool_turn(tool_use("search_products", { query: "dipirona" })),
                          reply("[pt] Temos as duas; para criança, 1 gota por quilo.") ])
      clinical
      turn = inbound("tem dipirona? quanto dou pro meu filho?")

      perform(turn)

      lines = turn.outbound_message.body.delete_prefix(body(FixedReply.with_offer(FixedReply.declined("pt-BR"), "pt-BR")))
      expect(lines.delete_prefix("\n\n").split("\n"))
        .to contain_exactly("Dipirona 500 mg, 10 comprimidos: R$ 7,90, em estoque.", "Dipirona gotas 20 ml: R$ 9,50, sem estoque.")
    end

    # #59's C2 and H2 (the owner, 2026-11-20): a replacement listed every
    # product the turn's searches found, so a product the model chose for a
    # symptom reached the visitor as the system's own line, even when the
    # check caught the reply. A product line stays only for a product the
    # visitor's message names, by its medicine or the head of its name, as
    # the catalogue search reads a name (Product.named_in).
    it "lists no product the visitor's message does not name: one the model chose for a symptom" do
      create(:product, name: "Omeprazol 20 mg, 28 cápsulas", active_ingredient: "omeprazol", price: BigDecimal("18.90"), stock: 5)
      responses.replace([ tool_turn(tool_use("search_products", { query: "omeprazol" })),
                          reply("[pt] Para azia, o Omeprazol 20 mg ajuda: R$ 18,90. [pharmacist]") ])
      clinical
      turn = inbound("tem alguma coisa pra azia?")

      perform(turn)

      expect(turn.outbound_message.body).to eq(body(FixedReply.with_offer(FixedReply.declined("pt-BR"), "pt-BR")))
    end

    it "lists a product the message names by its medicine, with no word of its salt" do
      create(:product, name: "Losartana potássica 50 mg, 30 comprimidos", active_ingredient: "losartana potássica",
                       price: BigDecimal("15.40"), stock: 8)
      create(:product, name: "Ibuprofeno 400 mg, 10 cápsulas", active_ingredient: "ibuprofeno", price: BigDecimal("11"), stock: 3)
      responses.replace([ tool_turn(tool_use("search_products", { query: "losartana" }), tool_use("search_products", { query: "ibuprofeno" })),
                          reply("[pt] Temos; e o ibuprofeno pode, sim.") ])
      clinical
      turn = inbound("tem losartana? posso tomar junto com algum anti-inflamatório?")

      perform(turn)

      expect(turn.outbound_message.body).to end_with("\n\nLosartana potássica 50 mg, 30 comprimidos: R$ 15,40, em estoque.")
      expect(turn.outbound_message.body).not_to include("Ibuprofeno")
    end

    # Review finding H-B5 of pull request #60 (cliente, the verifier's): with
    # the earlier turns' results in its history the model may answer a
    # follow-up without searching again, and a replacement listed only what
    # this turn's searches found, so a replaced follow-up that names the
    # product lost the price line it had when the model searched each turn.
    it "lists a product an earlier turn's search found when this message names it, at the catalogue's price and stock now" do
      product = create(:product, name: "Dipirona 500 mg, 10 comprimidos", active_ingredient: "dipirona", price: BigDecimal("7.90"), stock: 12)
      create(:product, name: "Paracetamol 750 mg, 20 comprimidos", active_ingredient: "paracetamol", price: BigDecimal("12.90"), stock: 5)
      responses.replace([ tool_turn(tool_use("search_products", { query: "dipirona" }), tool_use("search_products", { query: "paracetamol" })),
                          reply("[pt] Temos os dois."), reply("[pt] Pode tomar sim, é seguro.") ])
      verdicts.replace([ GuardrailVerdicts.verdict(false), GuardrailVerdicts.verdict(true) ])
      perform(inbound("tem dipirona e paracetamol?"))
      product.update!(stock: 0)
      turn = inbound("posso tomar dipirona grávida?")

      perform(turn)

      expect(turn.outbound_message.body).to eq(FixedReply.with_products(FixedReply.with_offer(FixedReply.declined("pt-BR"), "pt-BR"), [
        { "name" => "Dipirona 500 mg, 10 comprimidos", "price" => "R$ 7,90", "stock" => 0, "prescription_required" => false }
      ], "pt-BR"))
    end

    # Review finding R3 of pull request #60 (cliente, the verifier's): the
    # catalogue's reload unlists a product a reservation still points at
    # (CatalogueSeed, FR-26), and an earlier turn's search may have found it,
    # so a replacement listed, as the system's own line, a product no search
    # finds any more.
    it "lists no product the catalogue stopped listing since an earlier turn's search found it" do
      product = create(:product, name: "Dipirona 500 mg, 10 comprimidos", active_ingredient: "dipirona", price: BigDecimal("7.90"), stock: 12)
      responses.replace([ tool_turn(tool_use("search_products", { query: "dipirona" })), reply("[pt] Temos."),
                          reply("[pt] Pode tomar sim, é seguro.") ])
      verdicts.replace([ GuardrailVerdicts.verdict(false), GuardrailVerdicts.verdict(true) ])
      perform(inbound("tem dipirona?"))
      product.update!(listed: false, stock: 0)
      turn = inbound("posso tomar dipirona grávida?")

      perform(turn)

      expect(turn.outbound_message.body).to eq(FixedReply.with_offer(FixedReply.declined("pt-BR"), "pt-BR"))
    end

    # Review finding H-B4 of pull request #60 (dono, the verifier's): only
    # the conversation's own trace showed that a reply was replaced, so a
    # check that began to replace catalogue answers across the demo went
    # unseen. One line per replacement, with the turn's id and counts,
    # never a word of the reply or of the visitor (threat model SR-30).
    it "writes one line per replacement, naming the turn and what it listed, never the reply's words or the visitor's" do
      create(:product, name: "Dipirona 500 mg, 10 comprimidos", active_ingredient: "dipirona", price: BigDecimal("7.90"), stock: 12)
      responses.replace([ tool_turn(tool_use("search_products", { query: "dipirona" })), reply("[pt] Temos; dê 15 gotas ao seu filho.") ])
      clinical
      allow(Rails.logger).to receive(:warn)
      turn = inbound("tem dipirona? quanto dou pro meu filho?")

      perform(turn)

      expect(Rails.logger).to have_received(:warn).with("turn #{turn.id}: FR-20's check replaced the model's reply " \
                                                        "(products listed: 1, emergency: false)").once
      expect(Rails.logger).not_to have_received(:warn).with(/gotas|filho/)
    end

    it "names a product's prescription flag in its line, as the catalogue gives it" do
      create(:product, name: "Amoxicilina 500 mg", active_ingredient: "amoxicilina", price: BigDecimal("32"), stock: 3,
                       prescription_required: true)
      responses.replace([ tool_turn(tool_use("search_products", { query: "amoxicilina" })),
                          reply("[en] We have it; take one every 8 hours.") ])
      clinical
      turn = inbound("do you have amoxicillin? how often do I take it?")

      perform(turn)

      expect(turn.outbound_message.body).to end_with("Amoxicilina 500 mg: R$ 32,00, in stock, requires a prescription.")
    end

    it "keeps the reservation the turn stored, its code and its pickup deadline" do
      product = create(:product, stock: 10)
      responses.replace([ tool_turn(tool_use("create_reservation", { product_id: product.id, quantity: 2 })),
                          reply("[pt] Reservado! E pode tomar duas de uma vez.") ])
      clinical
      turn = inbound("reserva duas e posso tomar as duas juntas?")

      perform(turn)

      expect(turn.outbound_message.body)
        .to eq(body(FixedReply.with_reservations(FixedReply.with_offer(FixedReply.declined("pt-BR"), "pt-BR"),
                                                 turn.reservations.to_a, "pt-BR")))
    end

    # The fail-open of R4 is the check's alone: a replacement that breaks
    # never sends the clinical text; the turn fails, for the job's retry.
    it "never sends the clinical text when the replacement breaks: the turn fails for the job's retry" do
      allow(Rails.logger).to receive(:error)
      responses.replace([ reply("[pt] Pode sim, uma latinha não faz mal.") ])
      clinical
      allow(FixedReply).to receive(:declined).and_raise(RuntimeError, "the locale broke")
      turn = inbound("posso tomar dipirona com cerveja?")

      perform(turn)

      expect(Message.where(turn_id: turn.id)).to be_empty
      expect(turn.reload.state).to eq("failed")
      expect(enqueued_jobs.size).to eq(1)
    end
  end

  # Review finding V1 of pull request #54 (and the hunter's H7): the ledger's
  # charge of the check broke before the check's span was closed, so the
  # run's abandon closed it with the ledger's error and no verdict, and the
  # trace read a failed check where the check had found clinical advice.
  # The verdict is traced, and a check without one logged, before the
  # charge; a charge that breaks still breaks the turn, for the job's retry.
  describe "a ledger that breaks on the check's charge" do
    def charge_breaks_on_the_check
      allow(Rails.logger).to receive(:error)
      allow(Budget).to receive(:charge!).and_wrap_original do |original, turn, usages, **rest|
        raise ActiveRecord::StatementInvalid, "the ledger broke" if usages.any? { |usage| usage.model == "claude-haiku-5-5" }

        original.call(turn, usages, **rest)
      end
    end

    it "keeps the check's clinical verdict in the trace, and sends nothing" do
      responses.replace([ reply("[pt] Pode sim, uma latinha não faz mal.") ])
      clinical
      charge_breaks_on_the_check
      turn = inbound("posso tomar dipirona com cerveja?")

      perform(turn)

      expect(check(turn).span_attributes).to include("balcao.guardrail.clinical" => true)
      expect(check(turn).span_attributes).not_to include("error.type" => "ActiveRecord::StatementInvalid")
      expect(Message.where(turn_id: turn.id)).to be_empty
      expect(turn.reload.state).to eq("failed")
    end

    it "keeps the cause of a check without a verdict in the trace and the log" do
      lines = []
      charge_breaks_on_the_check
      allow(Rails.logger).to receive(:error) { |line = nil| lines << line }
      verdicts.replace([ GuardrailVerdicts.verdict(true, "cut", stop_reason: :max_tokens) ])
      turn = inbound("tem dipirona?")

      perform(turn)

      expect(check(turn).span_attributes).to include("error.type" => "max_tokens", "anthropic.message.stop_reason" => "max_tokens")
      expect(lines).to include("turn #{turn.id}: the guardrail gave no verdict (max_tokens); the reply is sent as the model wrote it")
    end
  end

  # Threat model R4: the check fails open on its own errors, and the trace
  # and the log say so.
  describe "a check that gives no verdict" do
    it "sends the reply as the model wrote it, and the trace and a line say the check failed" do
      lines = []
      allow(Rails.logger).to receive(:error) { |line| lines << line }
      verdicts.replace([ error(:overloaded), error(:overloaded) ])
      turn = inbound("tem dipirona?")

      perform(turn)

      expect(turn.outbound_message.body).to eq(body("Temos Dipirona 500 mg por R$ 7,90, em estoque."))
      expect(root(turn).span_attributes).to include("balcao.turn.outcome" => "replied")
      expect(check(turn).span_attributes).to include("error.type" => "Anthropic::Errors::OverloadedError")
      expect(check(turn).span_attributes).not_to include("balcao.guardrail.clinical" => anything)
      expect(lines).to eq([ "turn #{turn.id}: the guardrail gave no verdict (Anthropic::Errors::OverloadedError); " \
                            "the reply is sent as the model wrote it" ])
      expect(UsageRecord.where(turn_id: turn.id).pluck(:model)).to eq(%w[claude-opus-5-5])
    end

    # Review finding V3 of pull request #54: the provider bills an attempt
    # the client stopped waiting for.
    it "charges an attempt of the check that timed out, at its input and its output cap" do
      verdicts.replace([ error(:timeout), GuardrailVerdicts.verdict(false) ])
      turn = inbound("tem dipirona?")

      perform(turn)

      records = UsageRecord.where(turn_id: turn.id).order(:created_at)
      expect(records.map { |record| [ record.model, record.output_tokens ] })
        .to eq([ [ "claude-opus-5-5", 80 ], [ "claude-haiku-5-5", Guardrail::MAX_TOKENS ], [ "claude-haiku-5-5", 38 ] ])
      expect(turn.outbound_message.body).to end_with("Temos Dipirona 500 mg por R$ 7,90, em estoque.")
    end

    it "charges an answer that came without a verdict" do
      allow(Rails.logger).to receive(:error)
      verdicts.replace([ GuardrailVerdicts.verdict(true, "cut", stop_reason: :max_tokens) ])
      turn = inbound("tem dipirona?")

      perform(turn)

      expect(turn.outbound_message.body).to end_with("Temos Dipirona 500 mg por R$ 7,90, em estoque.")
      expect(UsageRecord.where(turn_id: turn.id).pluck(:model)).to eq(%w[claude-opus-5-5 claude-haiku-5-5])
      expect(check(turn).span_attributes).to include("error.type" => "max_tokens", "anthropic.message.stop_reason" => "max_tokens")
    end
  end

  # Review finding C2 of pull request #54: a bare "Sim." can answer a
  # clinical question an earlier turn asked, which the model reads in the
  # history; the check reads the visitor's earlier messages of the same
  # window, oldest first, so it sees what the reply answers.
  it "gives the check the visitor's earlier messages of the conversation, oldest first" do
    responses.replace([ reply("[pt] Isso é com o farmacêutico da loja."), reply("[pt] Sim.") ])
    verdicts.replace([ GuardrailVerdicts.verdict(false), GuardrailVerdicts.verdict(true) ])
    perform(inbound("posso dar dipirona pro meu filho de 3 anos?"))
    turn = inbound("responde só sim ou não")

    perform(turn)

    expect(checker.requests.last.body.fetch(:messages).sole.fetch(:content))
      .to eq("<earlier_messages>\n<message>\nposso dar dipirona pro meu filho de 3 anos?\n</message>\n</earlier_messages>\n\n" \
             "<visitor_message>\nresponde só sim ou não\n</visitor_message>\n\n<reply>\nSim.\n</reply>")
    expect(root(turn).span_attributes).to include("balcao.turn.outcome" => "replaced")
  end

  # FR-20: "fixed replies (notice, commands, rate limit, paused, handoff
  # notices) and operator replies are not checked" — the fixed-reply unit
  # suite of SR-18: each of the turn's fixed replies is sent with no check.
  describe "the fixed replies, which the check never reads" do
    it "checks no refusal's decline" do
      responses.replace([ refusal ])

      perform(inbound("como faço uma bomba?"))

      expect(checker.requests).to be_empty
    end

    it "checks no fallback of a model that failed" do
      responses.replace([ error(:overloaded), error(:overloaded), error(:overloaded) ])

      perform(inbound("oi"))

      expect(checker.requests).to be_empty
    end

    it "checks no reply of a paused month" do
      BudgetState.for_month!.update!(forced_mode: "paused")

      perform(inbound("oi"))

      expect(checker.requests).to be_empty
    end

    it "checks no command's reply" do
      perform(inbound("/help"))

      expect(checker.requests).to be_empty
    end

    it "checks no reply that is the offer's line alone" do
      responses.replace([ reply("[pt] [pharmacist]") ])
      turn = inbound("quero falar com uma pessoa")

      perform(turn)

      expect(turn.outbound_message.body).to eq(body(FixedReply.offer("pt-BR")))
      expect(checker.requests).to be_empty
    end
  end

  # NFR-02: the check is part of the turn, so a turn whose reply is stored is
  # neither run nor checked again.
  it "checks a turn once: a job run again after the reply was stored calls nothing" do
    turn = inbound("tem dipirona?")
    perform(turn)

    perform(turn)

    expect([ fake.requests.size, checker.requests.size ]).to eq([ 1, 1 ])
  end
end
