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

  before_validation { self.channel ||= conversation&.visitor&.channel }

  validates :channel, inclusion: { in: Visitor::CHANNELS.values }
  validates :body, presence: true

  # Stores an inbound message keyed by its channel's message id: Meta's on
  # WhatsApp, and on the web the id the client generates for each message, so
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

  # The message as the conversation's stream and the polling endpoint carry
  # it (FR-18): the turn of an inbound message is the caller's to give, and a
  # web message carries the id its client generated, so the page can match
  # it to the one it sent.
  def stream_payload(turn_id: self.turn_id, first_reply: first_reply?)
    { id:, client_id: (external_id if inbound? && channel == "web"), conversation_id:, turn_id:,
      **trace_payload(turn_id:, first_reply:).slice(:author, :notice, :body, :created_at) }
  end

  # The message as a trace page shows it (FR-12), to any holder of the link:
  # its words and its turn, and no id a page could take anywhere else. The
  # demo notice comes apart from the body of the reply that carries it
  # (FR-01; design §10, note of 2026-11-12).
  def trace_payload(turn_id: self.turn_id, first_reply: first_reply?)
    notice, text = first_reply ? notice_and_text : [ nil, body ]
    { id:, turn_id:, author:, notice:, body: text, created_at: created_at.iso8601(3) }
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

  def notice_and_text
    notice, text = body.split("\n\n", 2)
    text ? [ notice, text ] : [ nil, body ]
  end

  # Stores the one reply of a turn, in the turn's conversation or in the one
  # given: a reset's confirmation opens the conversation it starts (FR-04). A
  # retried job meets the unique index and gets the reply already stored, so
  # it neither stores nor sends a second one (NFR-02).
  def self.record_outbound!(turn:, body:, author: "bot", conversation: nil)
    create_or_find_by!(turn_id: turn.id) do |message|
      message.assign_attributes(conversation_id: conversation&.id || turn.conversation_id, direction: "outbound",
                                author:, source: "text", body:, status: "pending")
    end
  end
end
