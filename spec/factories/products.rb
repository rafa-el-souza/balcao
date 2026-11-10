FactoryBot.define do
  factory :product do
    sequence(:sku) { |n| "TEST-#{n}" }
    name { "Dipirona 500 mg, 10 comprimidos" }
    active_ingredient { "dipirona" }
    price { BigDecimal("8.90") }
    stock { 20 }
    prescription_required { false }
  end
end
