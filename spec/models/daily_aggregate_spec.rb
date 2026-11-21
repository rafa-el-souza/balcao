require "rails_helper"

# The day's counts (design §6.5): one row per day of São Paulo, kind and key,
# whose count a writer adds to; FR-17's canary is the first kind written, its
# passed and failed runs, which FR-13's pipeline uptime reads (M3-3).
RSpec.describe "NFR-02 FR-17 the day's counts, one row per day, kind and key" do
  it "opens the day's row on its first count and adds to it after" do
    travel_to Time.zone.local(2026, 11, 21, 10, 0) do
      DailyAggregate.add!(kind: "canary", key: "passed")
      DailyAggregate.add!(kind: "canary", key: "passed")
      DailyAggregate.add!(kind: "canary", key: "failed")
    end

    expect(DailyAggregate.order(:key).pluck(:day, :kind, :key, :count))
      .to eq([ [ Date.new(2026, 11, 21), "canary", "failed", 1 ], [ Date.new(2026, 11, 21), "canary", "passed", 2 ] ])
  end

  it "counts on São Paulo's day, whatever the host's zone: 01:30 UTC is still the day before there" do
    travel_to(Time.utc(2026, 11, 22, 1, 30)) { DailyAggregate.add!(kind: "canary", key: "passed") }

    expect(DailyAggregate.sole.day).to eq(Date.new(2026, 11, 21))
  end

  it "refuses a kind the design does not name" do
    expect { DailyAggregate.add!(kind: "visits", key: "passed") }.to raise_error(ArgumentError, /visits/)
  end

  # NFR-02's key: a second writer of the same day, kind and key adds to the
  # row the first one opened, never a second row and never RecordNotUnique.
  it "keeps one row per day, kind and key: a duplicate insert is refused by the database" do
    DailyAggregate.add!(kind: "canary", key: "passed")

    expect { DailyAggregate.insert_all!([ { day: Date.current, kind: "canary", key: "passed", count: 1 } ]) }
      .to raise_error(ActiveRecord::RecordNotUnique)
  end
end
