module Tools
  # One topic of the store sheet, config/store.yml (FR-03, FR-26): what the
  # system prompt does not carry, that is everything but the identity and the
  # hours. The topic is an enum in the strict schema and is checked again here
  # (SR-16), so a topic outside the five gets FR-03's answer, never a lookup.
  class GetStoreInfo < AgentTool
    REASONS = %w[unknown_topic].freeze

    class Input < Anthropic::BaseModel
      required :topic, Anthropic::EnumOf[*StoreSheet::TOPICS.map(&:to_sym)], doc: "The one topic to look up."
    end

    UNKNOWN = "No such topic. The topics are #{StoreSheet::TOPICS.join(", ")}. For anything else, answer from the " \
              "identity and the opening hours in your instructions, or say that you do not know and offer the " \
              "pharmacist on duty.".freeze

    doc "Look up one topic of the pharmacy's fact sheet: delivery (the neighbourhoods served, the fee and time " \
        "for each, and the rules), payment (the methods accepted and instalments), services (the in-store " \
        "services, their prices and whether one needs a prescription), contact (the phone and the pharmacist " \
        "on duty) or parking. Call it for any question on these before you answer, and answer with what it " \
        "returns, in the visitor's language. The address and the opening hours are already in your instructions."
    input_schema Input

    # The topics whose facts are a list, the list's key and what it holds;
    # the others are single facts (FR-12: the glass box counts lists only).
    LISTS = { "delivery" => %w[areas areas], "payment" => %w[methods methods], "services" => %w[list services] }.freeze

    def tally(result)
      key, unit = LISTS[result["topic"]]
      list = result[key] if key
      { unit:, count: list.size } if list.is_a?(Array)
    end

    def perform(input)
      topic = input.to_h[:topic].to_s
      facts = StoreSheet.current.topic(topic) or refuse(UNKNOWN, "unknown_topic")

      { "topic" => topic }.merge(facts)
    end
  end
end
