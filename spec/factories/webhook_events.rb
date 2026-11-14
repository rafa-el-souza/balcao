FactoryBot.define do
  factory :webhook_event do
    sequence(:update_id) { |n| 734_120_000 + n }
    kind { "message" }
    payload { { update_id:, message: { message_id: 1, text: "oi" } }.to_json }
    received_at { Time.current }
  end
end
