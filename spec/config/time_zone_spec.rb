require "rails_helper"

RSpec.describe "NFR-02 application time zone" do
  it "keeps business time in America/Sao_Paulo and stores UTC" do
    expect(Time.zone.name).to eq("America/Sao_Paulo")
    expect(ActiveRecord.default_timezone).to eq(:utc)
  end

  it "puts 23:30 in São Paulo on its own business day, which is the next day in UTC" do
    travel_to Time.zone.local(2026, 11, 9, 23, 30) do
      expect(Time.zone.today).to eq(Date.new(2026, 11, 9))
      expect(Time.now.utc.to_date).to eq(Date.new(2026, 11, 10))
    end
  end
end
