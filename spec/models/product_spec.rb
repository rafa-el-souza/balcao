require "rails_helper"

RSpec.describe "FR-07 SR-16 product stock and price" do
  def save_unchecked(product)
    Product.transaction(requires_new: true) { product.save!(validate: false) }
  end

  it "never holds negative stock, whatever writes it" do
    expect { save_unchecked(build(:product, stock: -1)) }
      .to raise_error(ActiveRecord::StatementInvalid, /products_stock_not_negative/)
  end

  it "never holds a negative price" do
    expect { save_unchecked(build(:product, price: -1)) }
      .to raise_error(ActiveRecord::StatementInvalid, /products_price_not_negative/)
  end

  it "keeps the seed key unique, so the nightly reset finds each product (FR-15)" do
    create(:product, sku: "DIP-500")

    expect { save_unchecked(build(:product, sku: "DIP-500")) }
      .to raise_error(ActiveRecord::RecordNotUnique, /"index_products_on_sku"/)
  end
end
