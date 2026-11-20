class AgentRunner
  # The conversation as the model reads it (design §6.3, FR-04): the last
  # thirty turns up to the one running, oldest first, each visitor message as a
  # user message. A visitor message carries the time it was sent, in São Paulo
  # time (design §1.4), in a text block of its own: the model reads "today" and
  # "now" from it, and since the line is built from the stored time, a past
  # message reads the same on every turn and the cached conversation holds.
  #
  # An earlier turn comes back as the model lived it (design §10, M2-11a): the
  # tool calls it made and their results, step by step, as the API read them
  # (Turn#tool_exchange), then the words it wrote (Message#authored). The
  # system's text after those words or in their place (the offer of the
  # pharmacist, the emergency line, a reservation's line, a decline, a
  # fallback, a command's answer) comes as the visitor read it, in a system
  # message, which names the visitor's message it followed by its time. The
  # history used to give a reply back whole, as the model's own words, with
  # the system's lines in it, which the prompt tells the model never to write,
  # and no tool result: the economy model disowned the offer's line as its
  # own, and doubted, then made again, a reservation whose code it had given
  # with nothing to back it (design §10, M2-4's note). A system message is
  # one no visitor can write: under a line in the user's turn, the text was
  # copied by a visitor to forge a reservation the economy model confirmed
  # (the slice's own probe). The demo notice the system put before a
  # conversation's first reply is left out, told by its place, not by its
  # wording (FR-01).
  #
  # The API takes the roles alternating, one message of each in a row, and a
  # system message only after a user message and before an assistant's or
  # last (arrange): a system's text waits for the next message the model
  # wrote, or the end, after the visitor's next message, and the texts that
  # wait together join into one. Tool results stay first in their user
  # message.
  module History
    TURNS = 30
    # The time a visitor's message was sent, as its time line and the system
    # messages that name it write it.
    SENT = "%A, %Y-%m-%d %H:%M (São Paulo time)".freeze
    AFTER = "After your reply to the visitor's message sent %<sent>s, the visitor read this text of the system's:".freeze
    INSTEAD = "In place of a reply of yours to the visitor's message sent %<sent>s, the visitor read this text of the system's:".freeze

    module_function

    def messages(turn)
      turns = Turn.where(conversation_id: turn.conversation_id)
                  .where("(turns.created_at, turns.id) <= (?, ?)", turn.created_at, turn.id)
                  .order(created_at: :desc, id: :desc).limit(TURNS)
                  .includes(:inbound_message, :outbound_message).to_a.reverse

      first = Message.first_reply_ids([ turn.conversation_id ])
      arrange(turns.flat_map { |past| [ visitor(past.inbound_message), *replied(past, first) ] })
    end

    def visitor(message)
      { role: "user", content: [ text("Sent #{sent(message)}"), text(message.body) ] }
    end

    # The turn's tool calls and their results, the words the model wrote and
    # the system's text; nothing for a turn with no reply, as the one running.
    def replied(turn, first)
      reply = turn.outbound_message or return []
      authored = reply.authored(first_reply: first.include?(reply.id))
      said = format(authored.attendant ? AFTER : INSTEAD, sent: sent(turn.inbound_message))
      [ *Array(turn.tool_exchange).map(&:deep_symbolize_keys),
        ({ role: "assistant", content: [ text(authored.attendant) ] } if authored.attendant),
        ({ role: "system", content: "#{said}\n#{authored.system}" } if authored.system) ].compact
    end

    def arrange(entries)
      waiting = []
      arranged = entries.each_with_object([]) do |entry, list|
        next waiting << entry[:content] if entry[:role] == "system"

        if entry[:role] == "assistant" && waiting.any?
          list << { role: "system", content: waiting.join("\n\n") }
          waiting = []
        end
        list.last&.dig(:role) == entry[:role] ? list.last[:content] += entry[:content] : list << entry.dup
      end
      waiting.any? ? arranged << { role: "system", content: waiting.join("\n\n") } : arranged
    end

    def sent(message) = message.created_at.in_time_zone.strftime(SENT)

    def text(text) = { type: "text", text: }
  end
end
