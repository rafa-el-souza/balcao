class Message < ApplicationRecord
  belongs_to :conversation
  # Set on outbound messages only: the turn that produced the reply.
  belongs_to :turn, optional: true
  belongs_to :webhook_event, optional: true

  # The domains of design §6.5. Prefixes keep the scopes off names that
  # Ruby and Active Record already use (system, read).
  enum :direction, { inbound: "inbound", outbound: "outbound" }, validate: true
  enum :author, { visitor: "visitor", bot: "bot", operator: "operator", system: "system" },
       prefix: :by, validate: true
  enum :source, { text: "text", audio: "audio", command: "command", canary: "canary" },
       prefix: true, validate: true
  enum :status, { pending: "pending", sent: "sent", delivered: "delivered", read: "read", failed: "failed" },
       prefix: true, validate: { allow_nil: true }

  # What a visitor sends, and what the attendant answers, is encrypted at rest
  # with keys that live in the env file, never in the database (threat model
  # SR-41); the app, and so the model, reads the plain text.
  #
  # A body an image before PR-18 wrote is plain text and is read as written:
  # Kamal runs the migration that encrypts the stored ones in the new web
  # container while the old containers still serve and answer turns, and a
  # return to such an image writes plain text again (review findings C1 and
  # V1 of pull request #32). The nightly job encrypts what is left
  # (NightlyResetJob). So a body that does not decrypt, should the keys ever
  # change, is read as its stored envelope rather than raised on; the keys
  # never rotate in place (bin/secrets-example).
  encrypts :body, support_unencrypted_data: true

  # PostgreSQL refuses a NUL in text: a body loses it, whoever wrote it, so a
  # model's reply carrying one is stored rather than breaking its turn on every
  # attempt (review finding V1 of pull request #18). The web intake drops it
  # already (Api::MessagesController).
  normalizes :body, with: ->(body) { body.delete("\u0000") }

  before_validation { self.channel ||= conversation&.visitor&.channel }

  validates :channel, inclusion: { in: Visitor::CHANNELS.values }
  validates :body, presence: true

  # Encrypts in place the bodies an image before PR-18 wrote in plain text,
  # for the nightly job (threat model SR-41; review finding V1 of pull request
  # #32), and answers how many. Only a row's stored value is read to tell.
  def self.encrypt_plain_bodies
    find_each.count do |message|
      next false if message.encrypted_attribute?(:body)

      message.encrypt
      true
    end
  end

  # Stores an inbound message keyed by its channel's message id: on Telegram
  # the visitor's row and Telegram's message id, which is counted per chat
  # (FR-19), and on the web the id the client generates for each message, so
  # a request sent again after its response was lost is stored once (review
  # finding N2 of pull request #7). A redelivered message meets the unique
  # index and returns the message already stored, even if its conversation
  # has closed since (SR-07, NFR-02). A web client chooses its ids, so an id
  # that another visitor's message holds is refused, never returned (SR-05).
  def self.record_inbound!(conversation:, external_id:, body:, source: "text", webhook_event: nil)
    raise ArgumentError, "an inbound message needs its channel's id (NFR-02)" if external_id.blank?

    visitor = conversation.visitor
    message = create_or_find_by!(channel: visitor.channel, external_id:) do |new_message|
      new_message.assign_attributes(conversation:, direction: "inbound", author: "visitor",
                                    source:, body:, webhook_event:)
    end
    return message if message.conversation.visitor_id == visitor.id

    raise ActiveRecord::RecordNotUnique, "the message id is held by another visitor's message"
  end

  # When the message reached the application, where NFR-01's latency starts:
  # for one that came in a Telegram update, the update's arrival at the
  # webhook, before the queue's wait and the job that stored the message;
  # for any other, as on the web, the request that stored it.
  def received_at = webhook_event&.received_at || created_at

  # The message as the conversation's stream and the polling endpoint carry
  # it (FR-18): the turn of an inbound message is the caller's to give, and a
  # web message carries the id its client generated, so the page can match
  # it to the one it sent. A reply lists the codes it writes of the visitor's
  # own reservations, the caller's to give, whatever conversation made them,
  # which the chat stamps (FR-07; docs/prototype/chat-reservation.html;
  # review finding C1 of pull request #19); the visitor's own words list none.
  def stream_payload(turn_id: self.turn_id, first_reply: first_reply?, reservation_codes: [])
    { id:, client_id: (external_id if inbound? && channel == "web"), conversation_id:, turn_id:,
      **trace_payload(turn_id:, first_reply:).slice(:author, :notice, :body, :created_at),
      codes: outbound? ? reservation_codes.select { |code| body.include?(code) } : [] }
  end

  # The message as a trace page shows it (FR-12), to any holder of the link:
  # its words and its turn, and no id a page could take anywhere else. The
  # demo notice comes apart from the body of the reply that carries it
  # (FR-01; design §10, note of 2026-11-12).
  def trace_payload(turn_id: self.turn_id, first_reply: first_reply?)
    notice, text = first_reply ? notice_and_text : [ nil, body ]
    { id:, turn_id:, author:, notice:, body: text, created_at: created_at.iso8601(3) }
  end

  # The reply as the model wrote it, for the history it reads back
  # (AgentRunner::History): without the notice the system put before it.
  def body_without_notice(first_reply: first_reply?) = first_reply ? notice_and_text.last : body

  # A reply in its authors' parts, for the history the model reads back
  # (AgentRunner::History; design §10, M2-11a): attendant, the words the
  # model wrote, which the reply begins with after any notice, and system,
  # the system's text after them or in their place, each nil when there is
  # none. TurnProcessor keeps the length of the model's words with the reply
  # (attendant_characters), so a fixed line a later slice adds is the
  # system's with no list of the fixed texts to keep. A reply stored before
  # that length was kept is the model's whole, as the history read it then.
  Authored = Data.define(:attendant, :system)

  def authored(first_reply: first_reply?)
    text = body_without_notice(first_reply:)
    return legacy_authored(text) if attendant_characters.nil?

    Authored.new(attendant: text[0, attendant_characters].presence,
                 system: text[attendant_characters..].to_s.delete_prefix("\n\n").presence)
  end

  # The first reply of a conversation is the one the system put the notice
  # before (TurnProcessor#record_reply), on its first line: it is told by its
  # place, not by its wording, which a later deploy may change (review finding
  # N1 of pull request #17). The callers that list messages know it already.
  def first_reply?
    outbound? && !Message.outbound.where(conversation_id:).where("(created_at, id) < (?, ?)", created_at, id).exists?
  end

  # The ids of the first reply of each of these conversations.
  def self.first_reply_ids(conversation_ids)
    outbound.where(conversation_id: conversation_ids).select("DISTINCT ON (conversation_id) messages.id")
            .order(:conversation_id, :created_at, :id).map(&:id).to_set
  end

  private

  # A reply stored before the model's share was kept: an image before M2-11a,
  # the old worker of Kamal's migration window, a rollback. The paragraphs a
  # turn adds after the model's words, the offer of the pharmacist, the
  # emergency line and a reservation's lines, are told by their text
  # (FixedReply.added_line?) and are the system's; the rest reads as the
  # model's, as the history read it then (review finding C1 of pull request
  # #60: the history gave those lines back as the model's own words while
  # the prompt says it never writes them).
  def legacy_authored(text)
    paragraphs = text.split("\n\n")
    added = []
    added.unshift(paragraphs.pop) while paragraphs.any? && FixedReply.added_line?(paragraphs.last)
    Authored.new(attendant: paragraphs.join("\n\n").presence, system: added.join("\n\n").presence)
  end

  def notice_and_text
    notice, text = body.split("\n\n", 2)
    text ? [ notice, text ] : [ nil, body ]
  end

  # Stores the one reply of a turn, in the turn's conversation or in the one
  # given: a reset's confirmation opens the conversation it starts (FR-04). A
  # retried job meets the unique index and gets the reply already stored, so
  # it neither stores nor sends a second one (NFR-02). attendant_characters
  # is the length of the words the model wrote, which the body begins with
  # after any notice, 0 for a text the system wrote in their place (authored).
  def self.record_outbound!(turn:, body:, author: "bot", conversation: nil, attendant_characters: nil)
    create_or_find_by!(turn_id: turn.id) do |message|
      message.assign_attributes(conversation_id: conversation&.id || turn.conversation_id, direction: "outbound",
                                author:, source: "text", body:, status: "pending", attendant_characters:)
    end
  end
end
