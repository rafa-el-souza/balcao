require "rails_helper"

# FR-14's modes (threat model SR-02 in full, ADR-0003, ADR-0012; design §9.2,
# M3-1): the month's spend at 70 % of its cap moves every new turn to the
# economy model, the day's spend at its slice of the cap (cap ÷ 30 × 1.5)
# does until midnight in São Paulo, and the cap pauses the month and alerts
# the operator once, through the bot (SR-35). The economy model serves only
# on ADR-0003's gate: with the gate closed, the month's economy pauses with
# the month's text and the day's until midnight with the day's, and the month
# goes on. The suite starts each example with the gate closed
# (spec/support/economy_gate.rb).
RSpec.describe "FR-14 SR-02 the budget's automatic modes: economy at 70 %, the daily slice, the pause at the cap" do
  include ActiveJob::TestHelper

  around do |example|
    @default_cap = Rails.configuration.x.budget_cap_usd
    Rails.configuration.x.budget_cap_usd = BigDecimal("10")
    example.run
  ensure
    Rails.configuration.x.budget_cap_usd = @default_cap
  end

  let(:turn) { create(:turn) }

  # A call of US$ 0.10 on the economy model's prices: 200,000 output tokens.
  def dime = AgentRunner::Usage.new(model: "claude-haiku-5-5", input_tokens: 0, output_tokens: 200_000, cache_creation_tokens: 0,
                                    cached_tokens: 0)

  def spend(times) = times.times { Budget.charge!(turn, [ dime ]) }

  def month = BudgetState.for_month!

  def opened = Rails.configuration.x.economy_allowed = true

  describe "the month at 70 % of its cap (ADR-0003)" do
    it "moves every new turn to economy from 70 % of the cap on, and is normal below it" do
      opened
      month.update!(spent_usd: BigDecimal("6.99"))
      expect(Budget.status).to eq(Budget::Status.new(mode: "normal", forced: false, daily: false))

      month.update!(spent_usd: BigDecimal("7"))
      expect(Budget.status).to eq(Budget::Status.new(mode: "economy", forced: false, daily: false))
      expect(month.automatic_mode).to eq("economy")

      month.update!(spent_usd: BigDecimal("10"))
      expect(Budget.mode).to eq("paused")
    end

    it "pauses, with the month's text, while the gate keeps the economy model from serving (ADR-0003)" do
      month.update!(spent_usd: BigDecimal("7"))

      expect(Budget.status).to eq(Budget::Status.new(mode: "paused", forced: false, daily: false))
      expect(month.automatic_mode).to eq("economy")
    end

    it "follows a cap a deploy raised: the same spend is normal again" do
      opened
      month.update!(spent_usd: BigDecimal("7"))
      expect(Budget.mode).to eq("economy")

      Rails.configuration.x.budget_cap_usd = BigDecimal("20")

      expect(Budget.mode).to eq("normal")
    end

    it "starts the next calendar month over in normal, a forced mode held (FR-14)" do
      opened
      travel_to(Time.zone.local(2026, 11, 30, 22, 0)) do
        month.update!(spent_usd: BigDecimal("8"))
        expect(Budget.mode).to eq("economy")
      end

      travel_to(Time.zone.local(2026, 12, 1, 0, 0, 1)) { expect(Budget.mode).to eq("normal") }
    end
  end

  describe "the day's slice (ADR-0012)" do
    it "is the cap ÷ 30 × 1.5" do
      expect(Budget.slice).to eq(BigDecimal("0.5"))

      Rails.configuration.x.budget_cap_usd = BigDecimal("100")
      expect(Budget.slice).to eq(BigDecimal("5"))
    end

    it "keeps the day's spend beside the month's, the day of São Paulo, started over by a new day's first charge" do
      travel_to(Time.zone.local(2026, 11, 21, 23, 30)) { spend(2) }
      expect(month).to have_attributes(day: Date.new(2026, 11, 21), day_spent_usd: BigDecimal("0.2"), spent_usd: BigDecimal("0.2"))

      # 00:10 in São Paulo, already 03:10 in UTC.
      travel_to(Time.zone.local(2026, 11, 22, 0, 10)) { spend(1) }
      expect(month).to have_attributes(day: Date.new(2026, 11, 22), day_spent_usd: BigDecimal("0.1"), spent_usd: BigDecimal("0.3"))
    end

    it "moves to economy once the day's spend reaches the slice, with no model call for the switch, until midnight" do
      opened
      travel_to(Time.zone.local(2026, 11, 21, 10, 0)) do
        spend(4)
        expect(Budget.mode).to eq("normal")

        spend(1)
        expect(Budget.status).to eq(Budget::Status.new(mode: "economy", forced: false, daily: false))
      end
      travel_to(Time.zone.local(2026, 11, 21, 23, 59, 59)) { expect(Budget.mode).to eq("economy") }

      travel_to(Time.zone.local(2026, 11, 22, 0, 0)) do
        expect(Budget.mode).to eq("normal")
        expect(month.automatic_mode).to eq("normal")
      end
    end

    it "pauses until midnight while the gate is closed, and the month goes on: the next day starts in normal" do
      travel_to(Time.zone.local(2026, 11, 21, 10, 0)) do
        spend(5)

        expect(Budget.status).to eq(Budget::Status.new(mode: "paused", forced: false, daily: true))
      end

      travel_to(Time.zone.local(2026, 11, 22, 0, 0, 1)) do
        expect(Budget.status).to eq(Budget::Status.new(mode: "normal", forced: false, daily: false))
      end
    end

    it "never pauses the month by itself: the month's own thresholds win over the day's" do
      travel_to(Time.zone.local(2026, 11, 21, 10, 0)) do
        month.update!(spent_usd: BigDecimal("7"))
        spend(5)

        expect(Budget.status).to eq(Budget::Status.new(mode: "paused", forced: false, daily: false))
      end
    end

    it "gives way to a forced mode, as the month's modes do (FR-14's kill switch)" do
      travel_to(Time.zone.local(2026, 11, 21, 10, 0)) do
        spend(5)
        Budget.force!(:normal)

        expect(Budget.status).to eq(Budget::Status.new(mode: "normal", forced: true, daily: false))
      end
    end
  end

  # The record: the read that finds the automatic mode changed writes it into
  # the month's row and one line, which names the day's spend beside the
  # month's, and says when the gate keeps an automatic economy from serving
  # that the demo pauses, and until when (#55's L4).
  describe "the month's line" do
    before { allow(Rails.logger).to receive(:warn) }

    it "names the month's spend and the day's, each against its limit" do
      travel_to(Time.zone.local(2026, 11, 21, 10, 0)) do
        opened
        spend(5)

        Budget.mode

        expect(Rails.logger).to have_received(:warn)
          .with("budget: 2026-11's automatic mode is economy at US$ 0.50 of its cap of US$ 10.00 " \
                "and US$ 0.50 of the day's slice of US$ 0.50").once
      end
    end

    it "says that an automatic economy the gate keeps closed pauses the demo until midnight, once" do
      travel_to(Time.zone.local(2026, 11, 21, 10, 0)) do
        spend(5)

        2.times { Budget.mode }

        expect(Rails.logger).to have_received(:warn)
          .with(/automatic mode is economy at .+; the economy model may not serve yet, so the demo pauses until midnight\z/).once
      end
    end

    it "says that the month's economy the gate keeps closed pauses the demo until the month ends, once a process" do
      month.update!(spent_usd: BigDecimal("7"), automatic_mode: "economy")

      2.times { Budget.mode }

      expect(Rails.logger).to have_received(:warn)
        .with(/automatic mode is economy at US\$ 7\.00 .+; the economy model may not serve yet, so the demo pauses until the month ends\z/).once
    end
  end

  # Review findings C1 = H1 and H4 of pull request #63 (dono): with ADR-0003's
  # gate closed, the month's economy is a pause until the month ends and the
  # day's slice one until midnight, which visitors cannot tell from the cap's
  # and no further spend would turn into the cap's alert; the operator hears
  # of each through the bot, once a month and cap, and once a day and cap.
  describe "the alert of a pause the closed gate makes" do
    before { allow(Rails.logger).to receive(:warn) }

    it "tells the operator once when the month's economy pauses the demo until the month ends" do
      month.update!(spent_usd: BigDecimal("7.10"))

      2.times { expect(Budget.mode).to eq("paused") }

      alert = OperatorAlert.sole
      expect(alert).to have_attributes(kind: "budget_month", key: "#{month.month}:10.0", status: "pending")
      expect(alert.text).to eq(I18n.t("operator.gate.month", locale: "pt-BR", month: month.month, spent: "7,10", cap: "10,00"))
      expect(OperatorAlertJob).to have_been_enqueued.with(alert.id).once
    end

    it "tells the operator once a day when the day's slice pauses the demo until midnight" do
      travel_to(Time.zone.local(2026, 11, 21, 10, 0)) do
        spend(5)
        2.times { Budget.mode }
      end
      travel_to(Time.zone.local(2026, 11, 22, 10, 0)) do
        spend(5)
        Budget.mode
      end

      expect(OperatorAlert.order(:created_at).pluck(:kind, :key))
        .to eq([ [ "budget_day", "2026-11-21:10.0" ], [ "budget_day", "2026-11-22:10.0" ] ])
      expect(OperatorAlert.order(:created_at).first.text)
        .to eq(I18n.t("operator.gate.day", locale: "pt-BR", day: "2026-11-21", day_spent: "0,50", slice: "0,50"))
    end

    it "holds no word of the conversation that made the spend" do
      reaching = create(:turn, inbound_message: create(:message, body: "Joana precisa da amoxicilina da receita"))
      month.update!(spent_usd: BigDecimal("7"))
      Budget.charge!(reaching, [ dime ])

      Budget.mode

      text = OperatorAlert.sole.text
      %w[Joana precisa amoxicilina receita].each { |word| expect(text).not_to include(word) }
    end
  end

  # FR-14: at the cap the operator is notified once, by the bot's alert,
  # which carries no word of a conversation (threat model SR-35).
  describe "the alert at the cap" do
    before { allow(Rails.logger).to receive(:warn) }

    it "is written once, by the read that finds the month paused, and sent by a job" do
      month.update!(spent_usd: BigDecimal("9.95"))
      spend(1)

      expect { 2.times { Budget.mode } }.to change(OperatorAlert, :count).by(1)

      alert = OperatorAlert.sole
      expect(alert).to have_attributes(kind: "budget_cap", key: "#{month.month}:10.0", status: "pending")
      expect(alert.text).to eq(I18n.t("operator.cap.paused", locale: "pt-BR", month: month.month, cap: "10,00", spent: "10,05"))
      expect(OperatorAlertJob).to have_been_enqueued.with(alert.id).once
    end

    it "holds no word of the conversation whose turn reached the cap, nor its id" do
      reaching = create(:turn, inbound_message: create(:message, body: "Joana precisa da amoxicilina da receita"))
      month.update!(spent_usd: BigDecimal("9.95"))
      Budget.charge!(reaching, [ dime ])

      Budget.mode

      text = OperatorAlert.sole.text
      %w[Joana precisa amoxicilina receita].each { |word| expect(text).not_to include(word) }
      expect(text).not_to include(reaching.conversation_id, reaching.conversation.visitor_id, reaching.id)
    end

    it "says which forced mode serves past the cap, in place of the pause" do
      month.update!(spent_usd: BigDecimal("12"), forced_mode: "normal")

      Budget.mode

      expect(OperatorAlert.sole.text)
        .to eq(I18n.t("operator.cap.serving", locale: "pt-BR", month: month.month, cap: "10,00", spent: "12,00", mode: "normal"))
    end

    # Review finding C2 = H10 of pull request #63 (dono): the cap's text told
    # the operator to raise the cap with a deploy when the pause was a mode
    # the operator forced, which holds whatever the cap is.
    it "says the forced mode holds the pause when the operator forced it, a pause or an economy the gate keeps closed" do
      %w[paused economy].each_with_index do |forced, index|
        BudgetState.delete_all
        OperatorAlert.delete_all
        Budget.instance_variable_set(:@alerted, nil)
        month.update!(spent_usd: BigDecimal("10.#{index}"), forced_mode: forced)

        expect(Budget.mode).to eq("paused")

        expect(OperatorAlert.sole.text)
          .to eq(I18n.t("operator.cap.forced", locale: "pt-BR", month: month.month, cap: "10,00", spent: "10,#{index}0")), forced
      end
    end

    # Review finding V1 of pull request #63 (dono, the verifier's): with the
    # gate closed, a raised cap may land the month in an economy the gate
    # pauses, so no text tells the operator that a deploy of a raised cap
    # resumes the demo; the runbook says what does.
    it "names no deploy as the way to resume, in the three languages, and points to the runbook" do
      %w[pt-BR en es].each do |locale|
        [ I18n.t("operator.cap.paused", locale:), I18n.t("operator.cap.forced", locale:), I18n.t("operator.gate.month", locale:) ].each do |text|
          expect(text).not_to include("deploy")
        end
        expect(I18n.t("operator.cap.paused", locale:)).to include("runbook")
      end
    end

    it "is written again when the month reaches a cap a deploy raised, once for each cap" do
      month.update!(spent_usd: BigDecimal("10"))
      Budget.mode
      Rails.configuration.x.budget_cap_usd = BigDecimal("20")
      Budget.mode
      month.update!(spent_usd: BigDecimal("20"))

      2.times { Budget.mode }

      expect(OperatorAlert.order(:created_at).pluck(:key)).to eq([ "#{month.month}:10.0", "#{month.month}:20.0" ])
    end

    it "is never written while the month's economy serves, nor for a pause the operator forced" do
      opened
      month.update!(spent_usd: BigDecimal("7"))
      Budget.mode
      Budget.force!(:paused)

      expect(OperatorAlert.count).to eq(0)
    end

    # Review finding C3 = H11 of pull request #63 (dono): the alert hung on
    # the read that moved the month's mode, so a month already recorded as
    # paused (before this code, or by a container without it in a deploy's
    # window) never got one. Any read while the cap holds writes it if it is
    # missing.
    it "is written by a read that finds the month already recorded as paused at its cap" do
      month.update_columns(spent_usd: BigDecimal("10"), automatic_mode: "paused")

      2.times { expect(Budget.mode).to eq("paused") }

      expect(OperatorAlert.where(kind: "budget_cap").count).to eq(1)
      expect(OperatorAlertJob).to have_been_enqueued.once
    end

    # Review finding C7 = H7 of pull request #63: the mode that serves is the
    # spend's whether or not the alert is written, so its write never breaks
    # a read; it is said once a process, not on every read, and the next
    # read tries again. The record of the mode is apart from it.
    it "never breaks a read when the alert cannot be written: one error line a process, and a later read writes it" do
      allow(Rails.logger).to receive(:error)
      month.update!(spent_usd: BigDecimal("10"))
      allow(OperatorAlert).to receive(:budget!).and_raise(ActiveRecord::StatementInvalid, "gone")

      3.times { expect(Budget.mode).to eq("paused") }

      expect(month.automatic_mode).to eq("paused")
      expect(Rails.logger).to have_received(:error)
        .with("budget: the operator's alert budget_cap #{month.month}:10.0 not written, ActiveRecord::StatementInvalid; " \
              "a later read tries again").once

      allow(OperatorAlert).to receive(:budget!).and_call_original
      Budget.mode

      expect(OperatorAlert.count).to eq(1)
    end
  end
end
