FactoryBot.define do
  factory :reservation do
    turn
    visitor { turn.conversation.visitor }
    product
    quantity { 2 }
    sequence(:code) { |n| format("T%05d", n) }
    pickup_until { 1.day.from_now.end_of_day }
  end
end
