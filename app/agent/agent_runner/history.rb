class AgentRunner
  # The conversation as the model reads it (design §6.3, FR-04): the last
  # thirty turns up to the one running, oldest first, each visitor message as a
  # user message. A visitor message carries the time it was sent, in São Paulo
  # time (design §1.4), in a text block of its own: the model reads "today" and
  # "now" from it, and since the line is built from the stored time, a past
  # message reads the same on every turn and the cached conversation holds.
  #
  # An earlier turn comes back as the model lived it, with only what it wrote
  # (design §10, M2-11a; the owner, 2026-11-20: "(d) Só o que o modelo
  # escreveu"): the tool calls it made and their results, step by step, as
  # the API read them (Turn#tool_exchange), then its reply as it wrote it, its
  # tags included (Turn#model_reply). The tags say which lines the system
  # added after the words, as the prompt tells, so no text of the system's
  # comes back. The history used to give a reply back whole, as the model's
  # own words, with the system's lines in it, which the prompt tells the
  # model never to write, and no tool result: the economy model disowned the
  # offer's line as its own, and doubted, then made again, a reservation
  # whose code it had given with nothing to back it (design §10, M2-4's
  # note). Given back as the system's, under a line in the user's turn, the
  # text was copied by a visitor to forge a reservation the economy model
  # confirmed, and in a system message, which carries the system prompt's
  # authority, it led the economy model to answer an English-speaking visitor
  # in Portuguese (the slice's own probe).
  #
  # When the system answered in the model's place (the check's replacement,
  # a refusal's decline, the fallback, a pause, a command's answer), one
  # fixed sentence in a system message says so and names the visitor's
  # message by its time, never quoting the text the visitor read (NOTICES;
  # the owner, 2026-11-20: "Aviso de uma frase"): what the application did is
  # what a system message in the conversation is for. A turn stored before
  # its turn kept these is read by its reply's text (Message#authored). The
  # demo notice the system put before a conversation's first reply never
  # comes back, told by its place, not by its wording (FR-01).
  #
  # The API takes the roles alternating, one message of each in a row, and a
  # system message only after a user message and before an assistant's or
  # last (arrange): a notice waits for the next message the model wrote, or
  # the end, after the visitor's next message, and the notices that wait
  # together join into one. Tool results stay first in their user message.
  module History
    TURNS = 30
    # The time a visitor's message was sent, as its time line and the
    # notices that name it write it.
    SENT = "%A, %Y-%m-%d %H:%M (São Paulo time)".freeze
    # What the system sent in the model's place (Turn::REPLY_KINDS), one
    # sentence each.
    NOTICES = {
      "decline" => "Your reply to the visitor's message sent %<sent>s did not reach the visitor: the system's check found " \
                   "clinical advice in it and sent the pharmacy's fixed decline, with the offer of the pharmacist, in its place.",
      "call_now" => "Your reply to the visitor's message sent %<sent>s did not reach the visitor: the system's check found " \
                    "clinical advice in it and sent, in its place, the call to call for help now and the emergency numbers.",
      "refusal" => "No reply of yours reached the visitor for their message sent %<sent>s: the system sent the pharmacy's " \
                   "fixed decline and the emergency numbers in its place.",
      "fallback" => "No reply of yours reached the visitor for their message sent %<sent>s: the system could not get one " \
                    "and sent its fixed apology in its place.",
      "pause" => "You were not asked about the visitor's message sent %<sent>s: the demo was paused, and the system sent " \
                 "its pause notice in place of a reply.",
      "reservations" => "No reply of yours reached the visitor for their message sent %<sent>s: the system sent the lines " \
                        "of the reservations you had made in its place.",
      "command" => "The visitor's message sent %<sent>s was a command, which the system answered with its fixed text in " \
                   "place of a reply of yours."
    }.freeze

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

    # The turn's tool calls and their results, then the reply as the model
    # wrote it or the notice of the fixed text the system sent in its place;
    # nothing for a turn with no reply, as the one running.
    def replied(turn, first)
      reply = turn.outbound_message or return []
      read = turn.reply_kind ? kept(turn) : reply.authored(first_reply: first.include?(reply.id))
      [ *Array(turn.tool_exchange).map(&:deep_symbolize_keys),
        ({ role: "assistant", content: [ text(read.written) ] } if read.written.present?),
        ({ role: "system", content: format(NOTICES.fetch(read.kind), sent: sent(turn.inbound_message)) } if read.kind) ].compact
    end

    # What the turn kept with its reply (TurnProcessor#replied).
    def kept(turn)
      return Message::Authored.new(written: turn.model_reply, kind: nil) if turn.reply_kind == "model"

      Message::Authored.new(written: nil, kind: turn.reply_kind)
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
