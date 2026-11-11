# Where an inbound message joins a conversation (design §6.3): it is stored in
# the visitor's open conversation, keyed by its channel's id (NFR-02), with
# its turn, and the turn is enqueued for ProcessTurnJob. The web channel calls
# it from POST /api/messages; WhatsApp joins with PR-18.
#
# - FR-04's 24-hour rule: a message that arrives 24 hours after the
#   conversation's last inbound message, or after its opening when it has
#   none, closes it and opens the next one, in the same language (design §1.4).
# - The open conversation's row is locked while the message and its turn are
#   stored, and re-read under the lock: a reset closes the conversation with
#   an UPDATE of that row, so it waits for the store, and its move then sees
#   the message; or the reset committed first, and the message goes to the
#   conversation it opened (review finding C5 of pull request #11).
# - A message sent again gets the turn already stored, in the conversation it
#   was stored in, and the turn is enqueued again while it has no reply (FR-18;
#   the job's run is a no-op once it has one).
class Intake
  SILENCE = 24.hours

  def initialize(visitor)
    @visitor = visitor
  end

  def receive!(external_id:, body:, source: "text")
    turn = stored(external_id) || store(external_id:, body:, source:)
    ProcessTurnJob.perform_later(turn.id) unless Message.exists?(turn_id: turn.id)
    turn
  end

  private

  # The turn of a message this visitor already sent with this id. An id that
  # another visitor's message holds raises RecordNotUnique (SR-05).
  def stored(external_id)
    message = Message.find_by(channel: @visitor.channel, external_id:) or return
    raise ActiveRecord::RecordNotUnique, "the message id is held by another visitor's message" unless
      message.conversation.visitor_id == @visitor.id

    Turn.for_inbound!(message)
  end

  def store(external_id:, body:, source:)
    loop do
      conversation = Conversation.current_for!(@visitor)
      turn = ApplicationRecord.transaction do
        conversation.lock!
        next if conversation.closed_at
        next close(conversation) if silent?(conversation)

        Turn.for_inbound!(Message.record_inbound!(conversation:, external_id:, body:, source:))
      end
      return turn if turn
    end
  end

  def silent?(conversation)
    last = conversation.messages.inbound.maximum(:created_at) || conversation.created_at
    last <= SILENCE.ago
  end

  # Closes a silent conversation; the next pass of the loop opens the next
  # one, which keeps the language the visitor was answered in (FR-02).
  def close(conversation)
    conversation.update!(closed_at: Time.current)
    Conversation.current_for!(@visitor).then { |opened| opened.update!(language: conversation.language) }
    nil
  end
end
