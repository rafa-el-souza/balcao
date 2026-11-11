require "rails_helper"

RSpec.describe "FR-06 FR-15 FR-26 the catalogue seed" do
  let(:written) { [] }

  after { written.each { |path| FileUtils.rm_f(path) } }

  def write_yaml(data)
    path = Rails.root.join("tmp", "catalogue-#{SecureRandom.hex(4)}.yml")
    File.write(path, data.to_yaml)
    written << path
    path
  end

  let(:product) do
    { "sku" => "dipirona-500mg-10cp", "name" => "Dipirona 500 mg, 10 comprimidos", "active_ingredient" => "dipirona",
      "price" => "7.90", "stock" => 40, "prescription_required" => false }
  end

  describe "db/seeds/catalogue.yml" do
    subject(:entries) { CatalogueSeed.entries }

    it "loads every product with its seed key, price as a decimal and a prescription flag" do
      expect(entries.size).to be >= 15
      expect(entries).to all(include(:sku, :name, :active_ingredient, :price, :stock, :prescription_required))
      expect(entries.map { |entry| entry[:price] }).to all(be_a(BigDecimal))
    end

    it "lists over-the-counter and prescription products, as the fictional pharmacy sells both (§1.2)" do
      expect(entries.map { |entry| entry[:prescription_required] }.uniq).to contain_exactly(true, false)
    end

    it "keeps one product out of stock, so the default demo can say so" do
      expect(entries.count { |entry| entry[:stock].zero? }).to eq 1
    end
  end

  describe "seeding" do
    it "creates every product of the seed" do
      expect { CatalogueSeed.seed! }.to change(Product, :count).from(0).to(CatalogueSeed.entries.size)
      expect(Product.find_by!(sku: "dipirona-500mg-10cp"))
        .to have_attributes(name: "Dipirona 500 mg, 10 comprimidos", price: BigDecimal("7.90"), prescription_required: false)
    end

    it "brings stock and price back to the seed when run again, without a second row (FR-15)" do
      CatalogueSeed.seed!
      Product.find_by!(sku: "dipirona-500mg-10cp").update!(stock: 1, price: BigDecimal("99"))

      expect { CatalogueSeed.seed! }.not_to change(Product, :count)
      expect(Product.find_by!(sku: "dipirona-500mg-10cp")).to have_attributes(stock: 40, price: BigDecimal("7.90"))
    end

    it "keeps the product's id, so reservations made before the reset still point at it" do
      CatalogueSeed.seed!
      id = Product.find_by!(sku: "dipirona-500mg-10cp").id

      CatalogueSeed.seed!

      expect(Product.find_by!(sku: "dipirona-500mg-10cp").id).to eq id
    end

    it "is what db:seed runs" do
      Rails.application.load_seed

      expect(Product.count).to eq CatalogueSeed.entries.size
    end
  end

  describe "an eval overlay (evals/README.md, Seeds)" do
    it "changes the fields it names on a product of the default seed" do
      overlay = write_yaml("products" => [ { "sku" => "dipirona-500mg-10cp", "stock" => 0 } ])

      dipirona = CatalogueSeed.entries(overlay:).find { |entry| entry[:sku] == "dipirona-500mg-10cp" }

      expect(dipirona).to include(stock: 0, price: BigDecimal("7.90"))
    end

    it "adds a product the default seed does not have" do
      overlay = write_yaml("products" => [ product.merge("sku" => "novo-produto", "name" => "Produto novo") ])

      expect(CatalogueSeed.entries(overlay:).map { |entry| entry[:sku] }).to include("novo-produto")
      expect(CatalogueSeed.entries(overlay:).size).to eq CatalogueSeed.entries.size + 1
    end

    it "refuses a new product that leaves a field out" do
      overlay = write_yaml("products" => [ { "sku" => "novo-produto", "name" => "Produto novo" } ])

      expect { CatalogueSeed.entries(overlay:) }.to raise_error(CatalogueSeed::Invalid, /novo-produto.*price/)
    end
  end

  describe "a malformed catalogue is refused with the product that is wrong" do
    {
      "a price that is a float" => [ { "price" => 7.9 }, /price must be a string like "7\.90"/ ],
      "a negative stock" => [ { "stock" => -1 }, /stock must be an integer of zero or more/ ],
      "a stock that is a string" => [ { "stock" => "40" }, /stock must be an integer of zero or more/ ],
      "a prescription flag that is not a boolean" => [ { "prescription_required" => "não" }, /prescription_required/ ],
      "a blank name" => [ { "name" => "" }, /name must be/ ],
      "an sku that is not a slug" => [ { "sku" => "Dipirona 500" }, /sku must be/ ],
      "an unknown field" => [ { "brand" => "Marca" }, /unknown field brand/ ]
    }.each do |label, (change, message)|
      it "refuses #{label}" do
        path = write_yaml("products" => [ product.merge(change) ])

        expect { CatalogueSeed.entries(path) }.to raise_error(CatalogueSeed::Invalid, message)
      end
    end

    it "refuses two products with one sku, which the seed key would merge" do
      path = write_yaml("products" => [ product, product.merge("name" => "Outro nome") ])

      expect { CatalogueSeed.entries(path) }.to raise_error(CatalogueSeed::Invalid, /sku dipirona-500mg-10cp appears twice/)
    end

    it "refuses two products with one name, which a search could not tell apart" do
      path = write_yaml("products" => [ product, product.merge("sku" => "outro") ])

      expect { CatalogueSeed.entries(path) }.to raise_error(CatalogueSeed::Invalid, /name .* appears twice/)
    end
  end
end
