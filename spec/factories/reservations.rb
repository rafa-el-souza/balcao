FactoryBot.define do
  factory :reservation do
    visitor
    product
    quantity { 2 }
    sequence(:idempotency_key) { |n| "toolu_test#{n}" }
    sequence(:code) { |n| format("T%05d", n) }
    pickup_until { 1.day.from_now.end_of_day }
  end
end
