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

  # Stores the one reply of a turn. A retried job meets the unique index and
  # gets the reply already stored, so it neither stores nor sends a second
  # one (NFR-02).
  def self.record_outbound!(turn:, body:, author: "bot")
    create_or_find_by!(turn_id: turn.id) do |message|
      message.assign_attributes(conversation_id: turn.conversation_id, direction: "outbound",
                                author:, source: "text", body:, status: "pending")
    end
  end
end
