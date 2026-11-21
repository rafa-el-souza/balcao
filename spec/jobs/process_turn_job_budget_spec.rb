require "rails_helper"

# The budget inside a turn (FR-14, threat model SR-02, design §6.4): the
# month's mode is read before any model call, a paused month answers with its
# fixed reply and calls nothing, and every model call a turn makes is charged
# at the price table's prices, with its cost on the call's span (FR-12).
RSpec.describe "FR-14 SR-02 FR-12 the budget in a turn: the pause before the model, the charge after it" do
  include ModelResponses
  include ActiveJob::TestHelper

  around do |example|
    @default_cap = Rails.configuration.x.budget_cap_usd
    Rails.configuration.x.budget_cap_usd = BigDecimal("10")
    example.run
  ensure
    Rails.configuration.x.budget_cap_usd = @default_cap
  end

  let(:conversation) { create(:conversation) }
  let(:responses) { [ reply("[pt] Olá! Em que posso ajudar?") ] }
  let(:fake) { FakeModel.new(responses) }

  before { allow(AgentRunner).to receive(:default_client) { fake.client } }

  def inbound(text)
    Turn.for_inbound!(Message.record_inbound!(conversation:, external_id: SecureRandom.uuid, body: text))
  end

  def perform(turn) = ProcessTurnJob.perform_now(turn.id)

  def root(turn) = TraceEvent.where(turn_id: turn.id, name: "balcao.turn").order(:started_at).last

  def calls(turn) = TraceEvent.where(turn_id: turn.id, name: TurnTrace::MODEL_CALL).order(:started_at)

  def month = BudgetState.find_by!(month: Time.current.strftime("%Y-%m"))

  describe "the charge" do
    it "charges every model call of the turn at the table's prices, with each call's cost on its span" do
      product = create(:product, name: "Dipirona 500 mg", active_ingredient: "dipirona")
      responses.replace([ tool_turn(tool_use("search_products", { query: "dipirona" })),
                          reply("[pt] Temos Dipirona 500 mg por R$ #{product.price}.", usage: usage(output: 120)) ])
      turn = inbound("tem dipirona?")

      perform(turn)

      costs = turn.usage_records.order(:created_at).pluck(:cost_usd)
      # 1,200 × 4 + 80 or 120 × 20 + 3,000 × 0.20, per million tokens; then
      # FR-20's check of the reply, 640 × 0.10 + 38 × 0.50.
      expect(costs).to eq([ BigDecimal("0.007"), BigDecimal("0.0078"), BigDecimal("0.000083") ])
      expect(calls(turn).map { |span| span.span_attributes["balcao.cost.usd"] }).to eq([ 0.007, 0.0078 ])
      expect(month.spent_usd).to eq(BigDecimal("0.014883"))
    end

    it "charges each attempt of a call a fallback model served, at that model's prices" do
      attempts = [ iteration(model: "claude-opus-5-5", input: 1000, output: 0),
                   iteration(model: "claude-opus-5", input: 1000, output: 100, fallback: true) ]
      responses.replace([ reply("[pt] Posso ajudar com isso.", model: "claude-opus-5",
                                                               usage: usage(input: 1000, output: 100, cache_read: 0, iterations: attempts)) ])
      turn = inbound("oi")

      perform(turn)

      expect(turn.usage_records.order(:created_at).pluck(:model, :cost_usd))
        .to eq([ [ "claude-opus-5-5", BigDecimal("0.004") ], [ "claude-opus-5", BigDecimal("0.0075") ],
                 [ "claude-haiku-5-5", BigDecimal("0.000083") ] ])
      expect(calls(turn).sole.span_attributes["balcao.cost.usd"]).to eq(0.0115)
    end

    it "keeps the charge of a call the turn made before it broke: the call was paid for" do
      allow(Rails.logger).to receive(:error)
      allow(Message).to receive(:record_outbound!).and_raise(ActiveRecord::ConnectionFailed, "gone")
      turn = inbound("oi")

      expect { perform(turn) }.to have_enqueued_job(ProcessTurnJob)

      # The model's call and FR-20's check of its reply.
      expect(turn.usage_records.pluck(:model)).to contain_exactly("claude-opus-5-5", "claude-haiku-5-5")
      expect(month.spent_usd).to eq(BigDecimal("0.007083"))
    end

    # The silent-failure review of pull request #29: a run that breaks
    # between two model calls, past the point where `charged` would already
    # have returned in a run that ends.
    it "charges the call a run made before it broke on its next call" do
      product = create(:product, name: "Dipirona 500 mg", active_ingredient: "dipirona")
      allow(Rails.logger).to receive(:error)
      responses.replace([ tool_turn(tool_use("search_products", { query: product.active_ingredient })) ])
      turn = inbound("tem dipirona?")
      allow(fake).to receive(:call).and_wrap_original do |original, request, nxt|
        raise ArgumentError, "a bug after the first call" if fake.requests.size == 1

        original.call(request, nxt)
      end

      expect { perform(turn) }.to have_enqueued_job(ProcessTurnJob)

      expect(turn.usage_records.count).to eq(1)
    end

    # Review finding V3 of pull request #29: a deploy stops the worker while a
    # turn runs; its thread is killed, and the calls it made are still charged.
    it "charges the calls a run made before its thread was killed" do
      waiting = Queue.new
      responses.replace([ tool_turn(tool_use("search_products", { query: "dipirona" })) ])
      allow(fake).to receive(:call).and_wrap_original do |original, request, nxt|
        if fake.requests.size == 1
          waiting << true
          sleep
        end
        original.call(request, nxt)
      end
      turn = inbound("tem dipirona?")

      worker = Thread.new { perform(turn) }
      waiting.pop(timeout: 10)
      worker.kill.join(10)

      expect(turn.usage_records.count).to eq(1)
      expect(month.spent_usd).to eq(BigDecimal("0.007"))
    end

    it "charges nothing for a turn run again once it has its reply (NFR-02)" do
      turn = inbound("oi")

      perform(turn)
      perform(turn)

      # The model's call and FR-20's check, once.
      expect(UsageRecord.count).to eq(2)
      expect(month.spent_usd).to eq(BigDecimal("0.007083"))
    end
  end

  describe "the pause" do
    it "answers with the pause's fixed reply and calls no model once the month reached its cap" do
      BudgetState.for_month!.update!(spent_usd: BigDecimal("10"))
      turn = inbound("tem dipirona?")

      perform(turn)

      expect(fake.requests).to be_empty
      expect(turn.reload).to have_attributes(state: "replied", mode: "paused", model: nil)
      expect(turn.outbound_message.body).to eq(FixedReply.with_notice(FixedReply.paused("pt-BR"), "pt-BR"))
      expect(root(turn).span_attributes).to include("balcao.turn.mode" => "paused", "balcao.turn.outcome" => "paused")
      expect(UsageRecord.count).to eq(0)
    end

    it "names no model on a turn run again in a month that paused after its first run broke" do
      turn = inbound("tem dipirona?")
      turn.update!(state: "failed", mode: "normal", model: "claude-opus-5-5")
      BudgetState.for_month!.update!(forced_mode: "paused")

      perform(turn)

      expect(turn.reload).to have_attributes(mode: "paused", model: nil, state: "replied")
    end

    # The owner's word of 2026-11-15 (E-08, question 37): the cap's text
    # names the month's limit, which a pause the operator forced did not
    # reach, so that pause answers with a text of its own, which names no
    # limit and no date.
    it "answers a forced pause with its own text, which names no limit, in the conversation's language" do
      conversation.update!(language: "es")
      BudgetState.for_month!.update!(forced_mode: "paused")
      turn = inbound("¿tienen ibuprofeno?")

      perform(turn)

      expect(fake.requests).to be_empty
      expect(turn.reload).to have_attributes(state: "replied", mode: "paused", model: nil)
      expect(turn.outbound_message.body).to eq(FixedReply.with_notice(FixedReply.forced_pause("es"), "es"))
      expect(root(turn).span_attributes).to include("balcao.turn.mode" => "paused", "balcao.turn.outcome" => "paused")
    end

    it "answers with the forced pause's text a forced economy, which pauses until the eval run allows it, past the cap too" do
      BudgetState.for_month!.update!(forced_mode: "economy", spent_usd: BigDecimal("12"))
      turn = inbound("tem dipirona?")

      perform(turn)

      expect(turn.outbound_message.body).to eq(FixedReply.with_notice(FixedReply.forced_pause("pt-BR"), "pt-BR"))
    end

    it "keeps the forced and the cap's texts apart in the three languages" do
      %w[pt-BR en es].each do |locale|
        expect(FixedReply.forced_pause(locale)).to be_present
        expect(FixedReply.forced_pause(locale)).not_to eq(FixedReply.paused(locale))
      end
      expect(FixedReply.forced_pause("pt-BR")).to eq("A demo está pausada no momento. Volte mais tarde.")
      expect(FixedReply.forced_pause("en")).to eq("The demo is paused for now. Please come back later.")
      expect(FixedReply.forced_pause("es")).to eq("La demo está en pausa por ahora. Vuelve más tarde.")
    end

    # Review finding C3 of pull request #29: the glass box's head follows the
    # month's mode, which the turn's own charge may have changed.
    # Past 70 % of the cap the month runs in economy (M3-1), so the turn that
    # reaches the cap runs on the economy model, with the gate open.
    it "closes a turn's root with the mode it ran in and the month's mode after its own charge" do
      Rails.configuration.x.economy_allowed = true
      BudgetState.for_month!.update!(spent_usd: BigDecimal("9.999"))
      turn = inbound("oi")

      perform(turn)

      expect(root(turn).span_attributes).to include("balcao.turn.mode" => "economy", "balcao.budget.mode" => "paused")
    end

    it "answers the turn that reaches the cap, and pauses the next one" do
      Rails.configuration.x.economy_allowed = true
      BudgetState.for_month!.update!(spent_usd: BigDecimal("9.999"))
      responses.replace([ reply("[pt] Olá!") ])
      first = inbound("oi")
      perform(first)
      second = inbound("tem dipirona?")

      perform(second)

      expect(first.reload.mode).to eq("economy")
      expect(second.reload.mode).to eq("paused")
      expect(fake.requests.size).to eq(1)
    end

    # M3-1 (SR-02 in full): the month's economy at 70 % of the cap and the
    # day's slice move the turn to the economy model, read before any model
    # call; with ADR-0003's gate closed the month's economy pauses with the
    # month's text and the day's slice until midnight with the day's.
    it "runs a turn of a month at 70 % of its cap on the economy model, with no model call for the switch" do
      Rails.configuration.x.economy_allowed = true
      BudgetState.for_month!.update!(spent_usd: BigDecimal("7"))
      turn = inbound("tem dipirona?")

      perform(turn)

      expect(fake.requests.map { |request| request.body[:model] }).to eq([ "claude-haiku-5-5" ])
      expect(turn.reload).to have_attributes(state: "replied", mode: "economy", model: "claude-haiku-5-5")
      expect(root(turn).span_attributes).to include("balcao.turn.mode" => "economy")
    end

    it "runs a turn of a day past its slice on the economy model until midnight, then on the normal one" do
      Rails.configuration.x.economy_allowed = true
      responses.replace([ reply("[pt] Olá!"), reply("[pt] Olá de novo!") ])
      travel_to(Time.zone.local(2026, 11, 21, 23, 0)) do
        BudgetState.for_month!.update!(day: Date.new(2026, 11, 21), day_spent_usd: BigDecimal("0.5"), spent_usd: BigDecimal("0.5"))
        perform(inbound("oi"))
      end

      travel_to(Time.zone.local(2026, 11, 22, 0, 0, 1)) { perform(inbound("tem dipirona?")) }

      expect(fake.requests.map { |request| request.body[:model] }).to eq([ "claude-haiku-5-5", "claude-opus-5-5" ])
    end

    it "pauses a turn of a day past its slice until midnight, with the day's text and no model call, while the gate is closed" do
      travel_to(Time.zone.local(2026, 11, 21, 15, 0)) do
        BudgetState.for_month!.update!(day: Date.new(2026, 11, 21), day_spent_usd: BigDecimal("0.5"), spent_usd: BigDecimal("0.5"))
        turn = inbound("tem dipirona?")

        perform(turn)

        expect(fake.requests).to be_empty
        expect(turn.reload).to have_attributes(state: "replied", mode: "paused", model: nil)
        expect(turn.outbound_message.body).to eq(FixedReply.with_notice(FixedReply.daily_pause("pt-BR"), "pt-BR"))
        expect(root(turn).span_attributes).to include("balcao.turn.outcome" => "paused")
      end
    end

    it "pauses a turn of a month at 70 % with the month's text and no model call, while the gate is closed" do
      BudgetState.for_month!.update!(spent_usd: BigDecimal("7"))
      turn = inbound("tem dipirona?")

      perform(turn)

      expect(fake.requests).to be_empty
      expect(turn.outbound_message.body).to eq(FixedReply.with_notice(FixedReply.paused("pt-BR"), "pt-BR"))
    end

    it "keeps the day's text apart from the month's and the forced pause's in the three languages" do
      %w[pt-BR en es].each do |locale|
        expect([ FixedReply.daily_pause(locale), FixedReply.paused(locale), FixedReply.forced_pause(locale) ].uniq.size).to eq(3)
        expect(FixedReply.in_place_kind(FixedReply.daily_pause(locale))).to eq("pause")
      end
      expect(FixedReply.daily_pause("pt-BR")).to eq("A demo está pausada até a meia-noite (horário de Brasília): chegou ao limite de gasto de hoje.")
    end

    it "still answers the commands, which call no model (FR-04, FR-05, FR-12)" do
      BudgetState.for_month!.update!(spent_usd: BigDecimal("12"))
      turn = inbound("/trace")

      perform(turn)

      expect(turn.outbound_message.body).to include("/trace#")
    end
  end

  # The glass box's words for the pause (web/src/locales, instrument.outcomes).
  it "lists the pause among the outcomes a root can carry" do
    expect(TurnProcessor::OUTCOMES).to include("paused")
  end
end
