# One inbound message and what the attendant did with it (design §6.3).
class Turn < ApplicationRecord
  belongs_to :conversation
  belongs_to :inbound_message, class_name: "Message"
  has_one :outbound_message, class_name: "Message"
  # The database deletes the turn's spans and usage with it (FR-15).
  has_many :trace_events
  has_many :usage_records

  enum :state, { received: "received", running: "running", replied: "replied", failed: "failed" },
       validate: true
  enum :mode, { normal: "normal", economy: "economy", paused: "paused", handoff: "handoff" },
       prefix: true, validate: { allow_nil: true }

  validate :inbound_message_is_inbound

  # The turn of an inbound message. A second call for the same message, from
  # a retry or a redelivery, meets the unique index and gets the turn already
  # created (NFR-02).
  def self.for_inbound!(message)
    create_or_find_by!(inbound_message_id: message.id) do |turn|
      turn.inbound_message = message
      turn.conversation_id = message.conversation_id
    end
  end

  private

  def inbound_message_is_inbound
    errors.add(:inbound_message, :invalid) if inbound_message && !inbound_message.inbound?
  end
end
