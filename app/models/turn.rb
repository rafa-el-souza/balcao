# One inbound message and what the attendant did with it (design §6.3).
class Turn < ApplicationRecord
  belongs_to :conversation
  belongs_to :inbound_message, class_name: "Message"
  has_one :outbound_message, class_name: "Message"
  # The database deletes the turn's spans and usage with it (FR-15); its
  # reservations stay, without their turn.
  has_many :trace_events
  has_many :usage_records
  has_many :reservations

  enum :state, { received: "received", running: "running", replied: "replied", failed: "failed" },
       validate: true
  enum :mode, { normal: "normal", economy: "economy", paused: "paused", handoff: "handoff" },
       prefix: true, validate: { allow_nil: true }

  # The tool calls the model made in the turn and their results, step by
  # step, as the API read them (AgentRunner::Result#exchange), which the
  # history of the later turns gives the model back (AgentRunner::History;
  # design §10, M2-11a). Kept with the reply, encrypted at rest: a call's
  # input may quote what the visitor sent (threat model SR-41).
  serialize :tool_exchange, coder: JSON
  encrypts :tool_exchange

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

  # NFR-01's figure, in ms: from the inbound message's receipt to the reply's
  # send. A web reply is sent as it is stored, to the page's stream, and
  # TurnProcessor writes the figure then; a Telegram reply leaves later, by
  # its status, and Telegram::Outbound writes it when the Bot API takes its
  # last part (reply_sent!), so a reply that never left has none.
  def latency_until(sent_at) = ((sent_at - inbound_message.received_at) * 1000).round

  def reply_sent!(at = Time.current) = update_columns(latency_ms: latency_until(at), updated_at: at)

  private

  def inbound_message_is_inbound
    errors.add(:inbound_message, :invalid) if inbound_message && !inbound_message.inbound?
  end
end
