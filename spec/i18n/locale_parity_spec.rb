require "rails_helper"

# The CI check that the three server locale files share the same keys
# (design NFR-09). The web app's files have their own check under web/src.
RSpec.describe "NFR-09 locale key parity (server)" do
  def flatten_keys(tree, prefix = nil)
    tree.flat_map do |key, value|
      path = [ prefix, key ].compact.join(".")
      value.is_a?(Hash) ? flatten_keys(value, path) : [ path ]
    end
  end

  let(:keys_by_locale) do
    Rails.root.glob("config/locales/**/*.yml").each_with_object(Hash.new { |hash, locale| hash[locale] = Set.new }) do |path, acc|
      YAML.safe_load_file(path).each { |locale, tree| acc[locale].merge(flatten_keys(tree)) }
    end
  end

  it "has a locale file for exactly pt-BR, en and es" do
    expect(keys_by_locale.keys).to contain_exactly("pt-BR", "en", "es")
  end

  it "has every key in every locale" do
    all_keys = keys_by_locale.values.reduce(Set.new, :|)
    missing = keys_by_locale.transform_values { |keys| (all_keys - keys).sort }.reject { |_, keys| keys.empty? }
    expect(missing).to eq({})
  end
end
