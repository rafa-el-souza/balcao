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
      # 1,200 × 4 + 80 or 120 × 20 + 3,000 × 0.20, per million tokens.
      expect(costs).to eq([ BigDecimal("0.007"), BigDecimal("0.0078") ])
      expect(calls(turn).map { |span| span.span_attributes["balcao.cost.usd"] }).to eq([ 0.007, 0.0078 ])
      expect(month.spent_usd).to eq(BigDecimal("0.0148"))
    end

    it "charges each attempt of a call a fallback model served, at that model's prices" do
      attempts = [ iteration(model: "claude-opus-5-5", input: 1000, output: 0),
                   iteration(model: "claude-opus-5", input: 1000, output: 100, fallback: true) ]
      responses.replace([ reply("[pt] Posso ajudar com isso.", model: "claude-opus-5",
                                                               usage: usage(input: 1000, output: 100, cache_read: 0, iterations: attempts)) ])
      turn = inbound("oi")

      perform(turn)

      expect(turn.usage_records.order(:created_at).pluck(:model, :cost_usd))
        .to eq([ [ "claude-opus-5-5", BigDecimal("0.004") ], [ "claude-opus-5", BigDecimal("0.0075") ] ])
      expect(calls(turn).sole.span_attributes["balcao.cost.usd"]).to eq(0.0115)
    end

    it "keeps the charge of a call the turn made before it broke: the call was paid for" do
      allow(Rails.logger).to receive(:error)
      allow(Message).to receive(:record_outbound!).and_raise(ActiveRecord::ConnectionFailed, "gone")
      turn = inbound("oi")

      expect { perform(turn) }.to have_enqueued_job(ProcessTurnJob)

      expect(turn.usage_records.count).to eq(1)
      expect(month.spent_usd).to eq(BigDecimal("0.007"))
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

      expect(UsageRecord.count).to eq(1)
      expect(month.spent_usd).to eq(BigDecimal("0.007"))
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

    it "answers a forced pause too, in the conversation's language" do
      conversation.update!(language: "es")
      BudgetState.for_month!.update!(forced_mode: "paused")
      turn = inbound("¿tienen ibuprofeno?")

      perform(turn)

      expect(fake.requests).to be_empty
      expect(turn.outbound_message.body).to eq(FixedReply.with_notice(FixedReply.paused("es"), "es"))
    end

    # Review finding C3 of pull request #29: the glass box's head follows the
    # month's mode, which the turn's own charge may have changed.
    it "closes a turn's root with the mode it ran in and the month's mode after its own charge" do
      BudgetState.for_month!.update!(spent_usd: BigDecimal("9.999"))
      turn = inbound("oi")

      perform(turn)

      expect(root(turn).span_attributes).to include("balcao.turn.mode" => "normal", "balcao.budget.mode" => "paused")
    end

    it "answers the turn that reaches the cap, and pauses the next one" do
      BudgetState.for_month!.update!(spent_usd: BigDecimal("9.999"))
      responses.replace([ reply("[pt] Olá!") ])
      first = inbound("oi")
      perform(first)
      second = inbound("tem dipirona?")

      perform(second)

      expect(first.reload.mode).to eq("normal")
      expect(second.reload.mode).to eq("paused")
      expect(fake.requests.size).to eq(1)
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
