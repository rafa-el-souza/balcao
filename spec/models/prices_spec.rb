require "rails_helper"

# The price table of the budget ledger (FR-14, ADR-0003) and the panel's rate
# of the real (FR-12): config/prices.yml, read from the provider's price page
# and the Banco Central's PTAX on the dates it carries (design §10, PR-16's
# note).
RSpec.describe "FR-14 FR-12 the price table, dated, and the rate of the real" do
  def usage(model:, input: 0, output: 0, write: 0, read: 0)
    AgentRunner::Usage.new(model:, input_tokens: input, output_tokens: output, cache_creation_tokens: write,
                           cached_tokens: read)
  end

  it "carries the date it was last verified, and the rate of the real its own" do
    expect(Prices.verified_on).to eq(Date.new(2026, 11, 14))
    expect(Prices.rate).to have_attributes(brl_per_usd: BigDecimal("5.6518"), verified_on: Date.new(2026, 11, 13))
  end

  it "prices every model a turn may name: both routes of ModelPolicy and the refusal fallback's targets" do
    routes = ModelPolicy::ROUTES.values.map(&:model)

    expect(Prices.models).to include(*routes, "claude-opus-5", "claude-opus-4-8")
  end

  it "has the four prices ADR-0003 names for every model, the cache write among them" do
    expect(Prices.price("claude-opus-5-5"))
      .to have_attributes(input: BigDecimal("4"), output: BigDecimal("20"), cache_write: BigDecimal("5"),
                          cache_read: BigDecimal("0.2"))
    expect(Prices.price("claude-haiku-5-5"))
      .to have_attributes(input: BigDecimal("0.1"), output: BigDecimal("0.5"), cache_write: BigDecimal("0.125"),
                          cache_read: BigDecimal("0.01"))
  end

  it "costs a call's usage with each kind of token at its own price, in US dollars" do
    cost = Prices.cost_usd(usage(model: "claude-opus-5-5", input: 1200, output: 80, write: 500, read: 3000))

    # 1,200 × 4 + 80 × 20 + 500 × 5 + 3,000 × 0.20, per million tokens.
    expect(cost).to eq(BigDecimal("0.0095"))
  end

  it "costs an attempt a fallback model served at that model's prices" do
    expect(Prices.cost_usd(usage(model: "claude-opus-5", input: 1000, output: 100))).to eq(BigDecimal("0.0075"))
  end

  it "costs a model the table does not list at the table's highest price of each kind, and says so in the log" do
    allow(Rails.logger).to receive(:warn)

    cost = Prices.cost_usd(usage(model: "claude-unknown-9", input: 1000, output: 100, write: 100, read: 1000))

    # 1,000 × 5 + 100 × 25 + 100 × 6.25 + 1,000 × 0.50, per million tokens.
    expect(cost).to eq(BigDecimal("0.008625"))
    expect(Rails.logger).to have_received(:warn).with(/claude-unknown-9.*highest/)
  end

  it "refuses a table with a model missing a price or a price that is not a decimal" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "prices.yml")
      File.write(path, <<~YAML)
        verified_on: "2026-11-14"
        models:
          claude-opus-5-5: { input: "4.00", output: "20.00", cache_read: "0.20" }
        brl: { per_usd: "5.6518", verified_on: "2026-11-13" }
      YAML

      expect { Prices.load(path) }.to raise_error(Prices::Invalid, /claude-opus-5-5.*cache_write/)

      File.write(path, File.read(path).sub('cache_read: "0.20"', 'cache_read: 0.2, cache_write: "5.00"'))
      expect { Prices.load(path) }.to raise_error(Prices::Invalid, /cache_read/)
    end
  end
end
