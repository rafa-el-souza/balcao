# The catalogue seed, db/seeds/catalogue.yml (FR-06, FR-26): read, checked,
# and written into products by sku, the seed key (FR-15). An eval overlay
# (evals/seeds/<name>.yml, evals/README.md) changes or adds products on top.
class CatalogueSeed
  PATH = Rails.root.join("db/seeds/catalogue.yml")
  FIELDS = %w[sku name active_ingredient price stock prescription_required].freeze
  SKU = /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/
  PRICE = /\A\d+\.\d{2}\z/

  class Invalid < StandardError; end

  # The products of the seed, with an overlay applied when one is given, as
  # attribute hashes ready for the products table.
  def self.entries(path = PATH, overlay: nil)
    products = read(path)
    products = apply(products, read(overlay)) if overlay
    raise Invalid, "#{path}: no products" if products.empty?

    check_unique(products)
    products.map { |product| check(product) }
  end

  # Makes the products table the seed (FR-26): creates the missing products
  # and brings every seeded one back to its seed values, keeping its row, so
  # reservations still point at it. A product the seed no longer lists is
  # deleted; while a reservation still points at it, it stays with no stock,
  # so no one reserves it, and a later run deletes it once the seven-day
  # purge has taken its reservations (FR-15; review finding C1 of pull
  # request #8). The stock written is the seed's, whatever is reserved: the
  # nightly reset subtracts the open reservations (FR-15, PR-16), so on a live
  # database this is a fresh start.
  def self.seed!(entries = self.entries)
    raise Invalid, "no products to seed" if entries.empty?

    Product.transaction do
      Product.upsert_all(entries, unique_by: :sku)
      removed = Product.where.not(sku: entries.map { |entry| entry[:sku] })
      removed.where.not(id: Reservation.select(:product_id)).delete_all
      removed.update_all(stock: 0)
    end
    entries.size
  end

  def self.read(path)
    data = YAML.safe_load_file(path)
    raise Invalid, "#{path}: must hold a `products` list" unless data.is_a?(Hash) && data["products"].is_a?(Array)

    data["products"].each do |product|
      raise Invalid, "#{path}: every product must be a mapping with a sku" unless product.is_a?(Hash) && product.key?("sku")

      unknown = product.keys - FIELDS
      raise Invalid, "#{path}: #{product["sku"]}: unknown field #{unknown.join(", ")}" if unknown.any?
    end
  rescue Psych::Exception => e
    raise Invalid, "#{path}: #{e.message}"
  end
  private_class_method :read

  # An overlay entry whose sku is in the seed changes the fields it names; any
  # other entry is a new product.
  def self.apply(products, changes)
    by_sku = products.index_by { |product| product["sku"] }
    changes.each do |change|
      by_sku[change["sku"]] = by_sku.fetch(change["sku"], {}).merge(change)
    end
    by_sku.values
  end
  private_class_method :apply

  def self.check_unique(products)
    %w[sku name].each do |field|
      repeated = products.map { |product| product[field] }.tally.find { |_, count| count > 1 }
      raise Invalid, "#{field} #{repeated.first} appears twice" if repeated
    end
  end
  private_class_method :check_unique

  def self.check(product)
    sku = product["sku"]
    missing = FIELDS - product.keys
    raise Invalid, "#{sku}: missing #{missing.join(", ")}" if missing.any?

    raise Invalid, "#{sku.inspect}: sku must be a lowercase slug" unless sku.is_a?(String) && sku.match?(SKU)
    raise Invalid, "#{sku}: name must be non-empty text" unless product["name"].is_a?(String) && product["name"].strip.present?
    unless product["active_ingredient"].nil? || (product["active_ingredient"].is_a?(String) && product["active_ingredient"].strip.present?)
      raise Invalid, "#{sku}: active_ingredient must be text or null"
    end
    raise Invalid, "#{sku}: price must be a string like \"7.90\"" unless product["price"].is_a?(String) && product["price"].match?(PRICE)
    raise Invalid, "#{sku}: stock must be an integer of zero or more" unless product["stock"].is_a?(Integer) && product["stock"] >= 0
    unless [ true, false ].include?(product["prescription_required"])
      raise Invalid, "#{sku}: prescription_required must be true or false"
    end

    product.transform_keys(&:to_sym).merge(price: BigDecimal(product["price"]))
  end
  private_class_method :check
end
