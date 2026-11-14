# The price table of the budget ledger and the rate of the real, from
# config/prices.yml (FR-14, FR-12, ADR-0003): what a model call cost, in US
# dollars, from the usage the API reported for it, each kind of token at its
# own price.
#
# A model the table does not list is costed at the table's highest price of
# each kind, and the log names it: a fallback model the API starts using is
# overcounted until the table has its row, never let through for free.
module Prices
  PATH = Rails.root.join("config/prices.yml")
  KINDS = %i[input output cache_write cache_read].freeze
  DECIMAL = /\A\d+(?:\.\d+)?\z/
  PER = 1_000_000

  Price = Data.define(*KINDS)
  Rate = Data.define(:brl_per_usd, :verified_on)
  Table = Data.define(:verified_on, :models, :rate)

  class Invalid < StandardError; end

  module_function

  def table = @table ||= load(PATH)

  def verified_on = table.verified_on

  def rate = table.rate

  def models = table.models.keys

  def price(model) = table.models.fetch(model)

  # The cost of one model call's usage (AgentRunner::Usage), unrounded.
  def cost_usd(usage)
    price = table.models.fetch(usage.model) { highest(usage.model) }
    tokens = { input: usage.input_tokens, output: usage.output_tokens, cache_write: usage.cache_creation_tokens,
               cache_read: usage.cached_tokens }
    KINDS.sum { |kind| tokens.fetch(kind) * price.public_send(kind) } / PER
  end

  def highest(model)
    Rails.logger.warn("prices: #{model} has no row in config/prices.yml; costed at the table's highest prices")
    Price.new(**KINDS.to_h { |kind| [ kind, table.models.values.map(&kind).max ] })
  end

  def load(path)
    data = YAML.safe_load_file(path)
    models = data.fetch("models").to_h { |model, row| [ model, price_of(model, row) ] }
    brl = data.fetch("brl")
    Table.new(verified_on: Date.iso8601(data.fetch("verified_on")), models: models.freeze,
              rate: Rate.new(brl_per_usd: decimal("brl.per_usd", brl.fetch("per_usd")),
                             verified_on: Date.iso8601(brl.fetch("verified_on"))))
  rescue KeyError, Date::Error, Psych::Exception => e
    raise Invalid, "#{path}: #{e.message}"
  end

  def price_of(model, row)
    missing = KINDS.map(&:to_s) - row.keys
    raise Invalid, "#{model}: missing #{missing.join(", ")}" if missing.any?

    Price.new(**KINDS.to_h { |kind| [ kind, decimal("#{model}.#{kind}", row.fetch(kind.to_s)) ] })
  end

  def decimal(name, value)
    raise Invalid, "#{name} must be a decimal string like \"4.00\"" unless value.is_a?(String) && value.match?(DECIMAL)

    BigDecimal(value)
  end
  private_class_method :highest, :price_of, :decimal
end
