require "rails_helper"

RSpec.describe "FR-21 SR-34 the landing's openers, resolved on the server" do
  subject(:openers) { Openers.load(Rails.root.join("config/openers.yml")) }

  it "has the three chips of FR-21: a stock question in Portuguese, a delivery one in Spanish, a clinical trap in Portuguese" do
    expect(openers.keys).to eq %w[stock_pt delivery_es clinical_pt]
    expect(openers.keys.map { |key| openers.fetch(key).lang }).to eq %w[pt es pt]
  end

  it "maps an allow-listed key to its text" do
    expect(openers.fetch("stock_pt")).to have_attributes(key: "stock_pt", lang: "pt", text: "tem dipirona?")
  end

  [
    "anything-else", "", "STOCK_PT", " stock_pt", "stock_pt\n", "stock_pt.text", "lang", "__proto__",
    nil, :stock_pt, [ "stock_pt" ], { "stock_pt" => "x" }, 1
  ].each do |key|
    it "sends nothing for #{key.inspect}" do
      expect(openers.fetch(key)).to be_nil
    end
  end

  it "is read from config/openers.yml once per process" do
    expect(Openers.current).to be(Openers.current)
    expect(Openers.current.keys).to eq openers.keys
  end

  describe "a malformed file is refused" do
    def load_with(data)
      path = Rails.root.join("tmp", "openers-#{SecureRandom.hex(4)}.yml")
      File.write(path, data.to_yaml)
      Openers.load(path)
    ensure
      FileUtils.rm_f(path)
    end

    it "refuses a language outside the three" do
      expect { load_with("stock_fr" => { "lang" => "fr", "text" => "vous avez ?" }) }
        .to raise_error(Openers::Invalid, /stock_fr\.lang must be one of pt, en, es/)
    end

    it "refuses a blank text, which would send an empty message" do
      expect { load_with("stock_pt" => { "lang" => "pt", "text" => " " }) }.to raise_error(Openers::Invalid, /stock_pt\.text/)
    end

    it "refuses a key that could not travel in a query string as is" do
      expect { load_with("stock pt" => { "lang" => "pt", "text" => "tem?" }) }.to raise_error(Openers::Invalid, /key "stock pt"/)
    end
  end
end
