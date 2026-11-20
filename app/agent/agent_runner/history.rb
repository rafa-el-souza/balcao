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
  # fallback, a command's answer) comes in the user's turn that follows, under
  # a line that names it the system's, as the visitor read it. The history
  # used to give a reply back whole, as the model's own words, with the
  # system's lines in it, which the prompt tells the model never to write, and
  # no tool result: the economy model disowned the offer's line as its own, and
  # doubted, then made again, a reservation whose code it had given with
  # nothing to back it (design §10, M2-4's note). A reply stored before the
  # model's share was kept reads whole as the model's, as before. The demo
  # notice the system put before a conversation's first reply is left out,
  # told by its place, not by its wording (FR-01).
  #
  # Messages of one role in a row join into one, as the API expects the roles
  # to alternate: visitor messages that got no reply, a step's tool results
  # and the system's text after them. The results stay first in theirs.
  module History
    TURNS = 30
    AFTER = "The system's text after your reply, as the visitor read it:".freeze
    INSTEAD = "The system's text in place of a reply of yours, as the visitor read it:".freeze

    module_function

    def messages(turn)
      turns = Turn.where(conversation_id: turn.conversation_id)
                  .where("(turns.created_at, turns.id) <= (?, ?)", turn.created_at, turn.id)
                  .order(created_at: :desc, id: :desc).limit(TURNS)
                  .includes(:inbound_message, :outbound_message).to_a.reverse

      first = Message.first_reply_ids([ turn.conversation_id ])
      turns.flat_map { |past| [ visitor(past.inbound_message), *replied(past, first) ] }
           .chunk_while { |before, after| before[:role] == after[:role] }
           .map { |run| { role: run.first[:role], content: run.flat_map { |message| message[:content] } } }
    end

    def visitor(message)
      sent = message.created_at.in_time_zone.strftime("Sent %A, %Y-%m-%d %H:%M (São Paulo time)")
      { role: "user", content: [ text(sent), text(message.body) ] }
    end

    # The turn's tool calls and their results, the words the model wrote and
    # the system's text; nothing for a turn with no reply, as the one running.
    def replied(turn, first)
      reply = turn.outbound_message or return []
      authored = reply.authored(first_reply: first.include?(reply.id))
      [ *Array(turn.tool_exchange).map(&:deep_symbolize_keys),
        ({ role: "assistant", content: [ text(authored.attendant) ] } if authored.attendant),
        ({ role: "user", content: [ text("#{authored.attendant ? AFTER : INSTEAD}\n#{authored.system}") ] } if authored.system) ].compact
    end

    def text(text) = { type: "text", text: }
  end
end
