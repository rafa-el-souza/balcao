FactoryBot.define do
  factory :message do
    conversation
    direction { "inbound" }
    author { "visitor" }
    source { "text" }
    body { "tem dipirona?" }
    channel { conversation.visitor.channel }

    factory :outbound_message do
      direction { "outbound" }
      author { "bot" }
      body { "Temos, sim." }
      status { "pending" }
      turn
      conversation { turn.conversation }
    end
  end
end
