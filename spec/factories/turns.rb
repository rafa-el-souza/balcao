FactoryBot.define do
  factory :turn do
    inbound_message factory: :message
    conversation { inbound_message.conversation }
  end
end
