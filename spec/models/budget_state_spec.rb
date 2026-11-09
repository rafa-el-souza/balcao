require "rails_helper"

RSpec.describe "NFR-02 FR-14 budget state, one row per calendar month in São Paulo" do
  it "opens the month in normal mode with nothing spent" do
    travel_to Time.zone.local(2026, 11, 15, 12, 0) do
      state = BudgetState.for_month!

      expect(state).to be_previously_new_record
      expect(state).to have_attributes(month: "2026-11", spent_usd: 0, automatic_mode: "normal", forced_mode: nil)
    end
  end

  it "counts 23:30 on the last day of the month in São Paulo, already the 1st in UTC, in that month" do
    travel_to Time.zone.local(2026, 11, 30, 23, 30) do
      expect(Time.now.utc.month).to eq(12)
      expect(BudgetState.for_month!.month).to eq("2026-11")
    end
  end

  it "returns the month already open, by the read alone" do
    open = create(:budget_state, month: "2026-11")

    travel_to Time.zone.local(2026, 11, 15, 12, 0) do
      result, raised = with_raised_exceptions { BudgetState.for_month! }

      expect(result).to eq(open)
      expect(raised).to be_empty
    end
  end

  it_behaves_like "an idempotency key", index: "index_budget_states_on_month" do
    let(:existing) { create(:budget_state, month: "2026-11") }
    let(:duplicate) { build(:budget_state, month: "2026-11") }
    let(:call_again) do
      lambda do
        # The read ran before the first turn of the month committed the row.
        allow(BudgetState).to receive(:find_by).and_return(nil)
        travel_to(Time.zone.local(2026, 11, 15, 12, 0)) { BudgetState.for_month! }
      end
    end
  end
end
