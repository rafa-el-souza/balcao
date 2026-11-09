FactoryBot.define do
  factory :webhook_event do
    sequence(:external_id) { |n| "wamid.TEST#{n}" }
    payload { { "object" => "whatsapp_business_account", "entry" => [] } }
    received_at { Time.current }
  end
end
