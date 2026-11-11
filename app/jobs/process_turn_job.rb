# Runs a turn (design §6.3): one job per inbound message, enqueued when the
# message is stored. At most one turn runs per conversation, under
# ConversationLock, and turns run in arrival order: a job that gets the lock
# first answers the conversation's earlier turns still waiting, oldest first,
# and then its own, so the model always reads the earlier replies (bursts of
# short messages are answered one by one). An earlier turn still running is
# one a crash or a deploy interrupted, since no other job can run it while
# this one holds the lock, so it is answered too (review finding C1 of pull
# request #11). An earlier turn that already ran and failed is left to its
# own job, so one broken turn never holds the conversation.
#
# A job run again for a turn that has its reply calls, bills and traces
# nothing (NFR-02). The retries with backoff and the dead letter of NFR-03
# arrive with PR-12.
class ProcessTurnJob < ApplicationJob
  queue_as :default

  def perform(turn_id)
    turn = Turn.find_by(id: turn_id)
    return if turn.nil? || Message.exists?(turn_id:)

    ConversationLock.hold(turn.conversation_id) do
      waiting_before(turn).each { |earlier| run_earlier(earlier) }
      # An earlier turn may have been a deletion that took this one (FR-05).
      turn = Turn.find_by(id: turn_id)
      TurnProcessor.new(turn).call if turn
    end
  end

  private

  def waiting_before(turn)
    Turn.where(conversation_id: turn.conversation_id, state: %w[received running])
        .where("(turns.created_at, turns.id) < (?, ?)", turn.created_at, turn.id)
        .where.missing(:outbound_message)
        .order(:created_at, :id)
  end

  # An earlier turn that breaks is marked failed by TurnProcessor and left to
  # its own job's retry; this job goes on to its own turn.
  def run_earlier(turn)
    turn = Turn.find_by(id: turn.id) or return
    TurnProcessor.new(turn).call
  rescue StandardError => e
    Rails.logger.error("earlier turn #{turn.id} failed: #{e.class}")
  end
end
