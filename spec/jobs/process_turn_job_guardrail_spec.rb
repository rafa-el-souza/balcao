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
    it "keeps the emergency line in place of the offer when the reply asked for it" do
      responses.replace([ reply("[pt] Dê bastante água e espere passar. [emergency]") ])
      clinical
      turn = inbound("meu filho engoliu uns comprimidos")

      perform(turn)

      expect(turn.outbound_message.body).to eq(body(FixedReply.with_emergency(FixedReply.declined("pt-BR"), "pt-BR")))
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
