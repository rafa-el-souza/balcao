FactoryBot.define do
  factory :message do
    conversation
    direction { "inbound" }
    author { "visitor" }
    source { "text" }
    body { "tem dipirona?" }
    channel { conversation.visitor.channel }
    # Every inbound message has its channel's id (NFR-02; the database's
    # messages_inbound_has_id); a reply has none.
    external_id { SecureRandom.uuid }

    factory :outbound_message do
      direction { "outbound" }
      author { "bot" }
      body { "Temos, sim." }
      status { "pending" }
      external_id { nil }
      turn
      conversation { turn.conversation }
    end
  end
end
