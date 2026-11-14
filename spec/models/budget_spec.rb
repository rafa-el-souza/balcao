require "rails_helper"

# The budget's ledger and its gate (FR-14, threat model SR-02, ADR-0003):
# every model call is charged to the calendar month in São Paulo at the price
# table's prices, and the month's mode is read before any model call. In the
# MVP the automatic mode is normal or, at the cap, paused; economy, the daily
# slice and the operator's notification arrive at M3 (design §9.1).
RSpec.describe "FR-14 SR-02 the budget: the ledger of model calls and the monthly cap's pause" do
  around do |example|
    @default_cap = Rails.configuration.x.budget_cap_usd
    Rails.configuration.x.budget_cap_usd = BigDecimal("10")
    example.run
  ensure
    Rails.configuration.x.budget_cap_usd = @default_cap
  end

  let(:turn) { create(:turn) }

  def usage(model: "claude-opus-5-5", input: 1200, output: 80, write: 0, read: 3000)
    AgentRunner::Usage.new(model:, input_tokens: input, output_tokens: output, cache_creation_tokens: write,
                           cached_tokens: read)
  end

  def month(at = Time.current) = BudgetState.find_by(month: at.in_time_zone.strftime("%Y-%m"))

  describe "the cap" do
    it "is US$ 100 unless the destination sets another (ADR-0003)" do
      expect(@default_cap).to eq(BigDecimal("100"))
      expect(Budget.cap).to eq(BigDecimal("10"))
    end
  end

  describe "the ledger" do
    it "writes one usage record per attempt, priced, and adds the cost to the month's spend" do
      travel_to Time.zone.local(2026, 11, 15, 12, 0) do
        total = Budget.charge!(turn, [ usage, usage(model: "claude-opus-5", input: 1000, output: 100, read: 0) ])

        expect(total).to eq(BigDecimal("0.007") + BigDecimal("0.0075"))
        expect(turn.usage_records.order(:created_at).map { |record| [ record.model, record.cost_usd ] })
          .to eq([ [ "claude-opus-5-5", BigDecimal("0.007") ], [ "claude-opus-5", BigDecimal("0.0075") ] ])
        expect(turn.usage_records.first).to have_attributes(input_tokens: 1200, output_tokens: 80, cached_tokens: 3000,
                                                            cache_creation_tokens: 0)
        expect(month.spent_usd).to eq(BigDecimal("0.0145"))
      end
    end

    it "charges nothing and opens no month for a call that reported no usage (a failed one)" do
      expect(Budget.charge!(turn, [])).to eq(0)
      expect(UsageRecord.count).to eq(0)
      expect(BudgetState.count).to eq(0)
    end

    it "keeps the month's spend after the seven-day purge has deleted its usage records (FR-15)" do
      travel_to Time.zone.local(2026, 11, 2, 12, 0) do
        Budget.charge!(turn, [ usage ])
      end
      UsageRecord.delete_all

      travel_to Time.zone.local(2026, 11, 20, 12, 0) do
        expect(month.spent_usd).to eq(BigDecimal("0.007"))
      end
    end

    it "charges the month of São Paulo, where 23:30 on the 30th is already December in UTC" do
      travel_to Time.zone.local(2026, 11, 30, 23, 30) do
        Budget.charge!(turn, [ usage ])
      end

      expect(BudgetState.sole.month).to eq("2026-11")
    end

    # Turns of different conversations run at once (three worker threads):
    # each charge adds to the spend the database holds, under the row's lock,
    # never to a copy read before another charge committed.
    it "adds to the spend the database holds, never to a copy read before another charge" do
      stale = BudgetState.for_month!
      BudgetState.where(id: stale.id).update_all(spent_usd: BigDecimal("5"))
      allow(BudgetState).to receive(:for_month!).and_return(stale)

      Budget.charge!(turn, [ usage ])

      expect(stale.reload.spent_usd).to eq(BigDecimal("5.007"))
    end

    it "charges the spend alone, leaving the mode to the read that comes next" do
      BudgetState.for_month!.update!(spent_usd: BigDecimal("9.995"))

      Budget.charge!(turn, [ usage ])

      expect(month).to have_attributes(spent_usd: BigDecimal("10.002"), automatic_mode: "normal")
    end
  end

  # Review finding S3 of pull request #29: the row and the log say what the
  # cap says when the mode is read, whatever changed it (a charge, a cap a
  # deploy changed), and what serves when a forced mode wins.
  describe "the record of the automatic mode" do
    before { allow(Rails.logger).to receive(:warn) }

    it "writes the pause into the month's row and one line, at the first read past the cap" do
      BudgetState.for_month!.update!(spent_usd: BigDecimal("9.995"))
      Budget.charge!(turn, [ usage ])

      2.times { expect(Budget.mode).to eq("paused") }

      expect(month.automatic_mode).to eq("paused")
      expect(Rails.logger).to have_received(:warn)
        .with("budget: #{month.month}'s automatic mode is paused at US$ 10.00 of its cap of US$ 10.00").once
    end

    it "says which forced mode serves past the cap, never that the demo paused" do
      BudgetState.for_month!.update!(spent_usd: BigDecimal("12"), forced_mode: "normal")

      expect(Budget.mode).to eq("normal")

      expect(Rails.logger).to have_received(:warn)
        .with(/automatic mode is paused at US\$ 12\.00 of its cap of US\$ 10\.00; the forced normal mode serves\z/)
    end

    # Review finding R1 of pull request #29: a forced economy pauses until
    # the eval run allows the economy model; the line says so.
    it "never says a forced economy serves while the month pauses" do
      BudgetState.for_month!.update!(spent_usd: BigDecimal("12"), forced_mode: "economy")

      expect(Budget.mode).to eq("paused")

      expect(Rails.logger).not_to have_received(:warn).with(/the forced economy mode serves/)
      expect(Rails.logger).to have_received(:warn)
        .with(/automatic mode is paused at US\$ 12\.00 of its cap of US\$ 10\.00; the forced economy mode may not serve yet, so the demo pauses\z/)
    end

    it "follows a cap a deploy lowered below the spend, and one it raised" do
      BudgetState.for_month!.update!(spent_usd: BigDecimal("5"))
      Rails.configuration.x.budget_cap_usd = BigDecimal("4")

      expect(Budget.mode).to eq("paused")
      expect(month.automatic_mode).to eq("paused")

      Rails.configuration.x.budget_cap_usd = BigDecimal("15")

      expect(Budget.mode).to eq("normal")
      expect(month.automatic_mode).to eq("normal")
      expect(Rails.logger).to have_received(:warn).with(/automatic mode is normal at US\$ 5\.00 of its cap of US\$ 15\.00\z/)
    end
  end

  describe "the mode, read before any model call" do
    it "is normal for a month with nothing spent, or none charged yet" do
      expect(Budget.mode).to eq("normal")
    end

    it "is normal below the cap" do
      BudgetState.for_month!.update!(spent_usd: BigDecimal("9.99"))

      expect(Budget.mode).to eq("normal")
    end

    it "is paused from the cap on, whatever the row's last written mode" do
      BudgetState.for_month!.update!(spent_usd: BigDecimal("10"), automatic_mode: "normal")

      expect(Budget.mode).to eq("paused")
    end

    it "follows a cap the destination raised: the same spend no longer pauses" do
      BudgetState.for_month!.update!(spent_usd: BigDecimal("10"), automatic_mode: "paused")
      Rails.configuration.x.budget_cap_usd = BigDecimal("15")

      expect(Budget.mode).to eq("normal")
    end

    it "starts the next calendar month over in normal (FR-14)" do
      travel_to(Time.zone.local(2026, 11, 30, 22, 0)) { BudgetState.for_month!.update!(spent_usd: BigDecimal("12")) }

      travel_to(Time.zone.local(2026, 12, 1, 0, 1)) { expect(Budget.mode).to eq("normal") }
    end

    it "keeps a forced mode over the automatic one until it is released (FR-14's kill switch)" do
      BudgetState.for_month!.update!(forced_mode: "paused")
      expect(Budget.mode).to eq("paused")

      BudgetState.for_month!.update!(forced_mode: "normal", spent_usd: BigDecimal("11"))
      expect(Budget.mode).to eq("normal")
    end

    # ADR-0003: economy serves only while the boundary suite last passed at
    # 100 % on the economy model; the full eval run records it from M2.
    it "pauses a forced economy while the economy model is not allowed to serve" do
      BudgetState.for_month!.update!(forced_mode: "economy")

      allow(Budget).to receive(:economy_allowed?).and_return(false)
      expect(Budget.mode).to eq("paused")

      allow(Budget).to receive(:economy_allowed?).and_return(true)
      expect(Budget.mode).to eq("economy")
    end

    it "allows the economy model only on the full eval run's word, which no file holds before M2" do
      expect(Budget.economy_allowed?).to be(false)
    end
  end
end
