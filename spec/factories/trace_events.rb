FactoryBot.define do
  factory :trace_event do
    turn
    trace_id { SecureRandom.hex(16) }
    span_id { SecureRandom.hex(8) }
    name { "turn" }
    started_at { Time.current }
  end
end
