FactoryBot.define do
  factory :webhook_event do
    sequence(:body_sha256) { |n| Digest::SHA256.hexdigest("webhook body #{n}") }
    payload { { "object" => "whatsapp_business_account", "entry" => [] } }
    received_at { Time.current }
  end
end
