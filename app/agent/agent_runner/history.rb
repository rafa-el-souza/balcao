class AgentRunner
  # The conversation as the model reads it (design §6.3, FR-04): the last
  # thirty turns up to the one running, oldest first, each visitor message as a
  # user message and each reply as an assistant message. A visitor message
  # carries the time it was sent, in São Paulo time (design §1.4), in a text
  # block of its own: the model reads "today" and "now" from it, and since the
  # line is built from the stored time, a past message reads the same on every
  # turn and the cached conversation holds. Visitor messages that got no reply
  # join into one user message, as the API expects the roles to alternate.
  module History
    TURNS = 30

    module_function

    def messages(turn)
      turns = Turn.where(conversation_id: turn.conversation_id)
                  .where("(turns.created_at, turns.id) <= (?, ?)", turn.created_at, turn.id)
                  .order(created_at: :desc, id: :desc).limit(TURNS)
                  .includes(:inbound_message, :outbound_message).to_a.reverse

      turns.flat_map { |past| [ visitor(past.inbound_message), (reply(past.outbound_message) if past.outbound_message) ] }
           .compact
           .chunk_while { |before, after| before[:role] == after[:role] }
           .map { |run| { role: run.first[:role], content: run.flat_map { |message| message[:content] } } }
    end

    def visitor(message)
      sent = message.created_at.in_time_zone.strftime("Sent %A, %Y-%m-%d %H:%M (São Paulo time)")
      { role: "user", content: [ text(sent), text(message.body) ] }
    end

    def reply(message) = { role: "assistant", content: [ text(message.body) ] }

    def text(text) = { type: "text", text: }
  end
end
