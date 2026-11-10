FactoryBot.define do
  factory :visitor do
    channel { "web" }
    sequence(:identity_hash) { |n| Digest::SHA256.hexdigest("visitor-#{n}") }
  end
end
