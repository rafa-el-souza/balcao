# Runs a turn (design §6.3): one job per inbound message, enqueued when the
# message is stored. At most one turn runs per conversation, under
# ConversationLock, and turns run in arrival order: a job that gets the lock
# first answers the conversation's earlier turns still waiting, oldest first,
# and then its own, so the model always reads the earlier replies (bursts of
# short messages are answered one by one). An earlier turn still running is
# one a crash or a deploy interrupted, since no other job can run it while
# this one holds the lock, so it is answered too (review finding C1 of pull
# request #11). So is one that failed and waits for its own job's next
# attempt: answered later, it would come after the later turns' replies, and
# its model, reading the conversation only up to it, would answer again what
# they had answered (review finding C1 of pull request #18). One that breaks
# again is left to its own job, so one broken turn never holds the
# conversation.
#
# A job run again for a turn that has its reply calls, bills and traces
# nothing (NFR-02).
#
# NFR-03: a turn the model cannot answer ends with the fallback text inside
# its run, so the job has nothing to try again (the three attempts of a model
# call are the SDK's, AgentRunner::MAX_RETRIES). A turn that breaks outside
# the model (the database, a bug) is tried again, three attempts in all, after
# about 3 s and then about 18 s; after the third the job lands in the dead
# letter: its line in the log, the fallback to the visitor (never a silent
# drop), and the error raised on, which Solid Queue keeps as a failed
# execution, the dead letter the console reads (FR-16, M2).
class ProcessTurnJob < ApplicationJob
  ATTEMPTS = 3

  queue_as :default

  retry_on StandardError, wait: :polynomially_longer, attempts: ATTEMPTS
  # Active Job raises the turn's error after these, unless one of them raises
  # its own; so the dead letter never raises (Active Job's run_after_discard_procs).
  after_discard { |_job, error| dead_letter(error) }

  def perform(turn_id)
    under_lock(turn_id) do |turn|
      waiting_before(turn).each { |earlier| run_earlier(earlier.id, turn.conversation_id) }
      # An earlier turn may have been a deletion that took this one (FR-05),
      # or a reset that moved it.
      settled(turn) { |own| TurnProcessor.new(own).call }
    end
  end

  private

  # Yields the turn under its conversation's lock, unless it is gone or has
  # its reply. When the block answers :moved, a reset moved the turn into the
  # conversation it opened while this job waited, and the turn is yielded
  # again under that conversation's lock: a turn runs only under the lock of
  # the conversation it belongs to (review finding R1 of pull request #11).
  def under_lock(turn_id)
    loop do
      turn = Turn.find_by(id: turn_id)
      return if turn.nil? || Message.exists?(turn_id:)
      return unless ConversationLock.hold(turn.conversation_id) { yield turn } == :moved
    end
  end

  # The turn as it is now, under the lock taken for it: nothing when a
  # deletion took it, :moved when a reset moved it.
  def settled(turn)
    now = Turn.find_by(id: turn.id)
    return if now.nil?
    return :moved if now.conversation_id != turn.conversation_id

    yield now
    nil
  end

  def waiting_before(turn)
    Turn.where(conversation_id: turn.conversation_id, state: %w[received running failed])
        .where("(turns.created_at, turns.id) < (?, ?)", turn.created_at, turn.id)
        .where.missing(:outbound_message)
        .order(:created_at, :id)
  end

  # An earlier turn that breaks is marked failed by TurnProcessor and left to
  # its own job's next attempt, or to the next turn's job when its own is gone;
  # this job goes on to its own turn. One that a reset among them moved
  # belongs to another lock now.
  def run_earlier(turn_id, conversation_id)
    turn = Turn.find_by(id: turn_id)
    return if turn.nil? || turn.conversation_id != conversation_id

    TurnProcessor.new(turn).call
  rescue StandardError => e
    Rails.logger.error("earlier turn #{turn_id} failed: #{e.class}")
  end

  # The job's last attempt failed (NFR-03). The line names the job, which
  # Solid Queue keeps as a failed execution, the turn and the error by its
  # class alone, never its message, which may quote what the visitor wrote
  # (SR-30). Then the visitor gets the fallback, under the conversation's
  # lock like any reply of the turn.
  def dead_letter(error)
    turn_id = arguments.first
    Rails.logger.error("dead letter: #{self.class} #{job_id}, turn #{turn_id}, #{executions} attempts, #{error.class}")
    under_lock(turn_id) { |turn| settled(turn) { |own| TurnProcessor.new(own).give_up(error) } }
  rescue StandardError => e
    Rails.logger.error("dead letter: turn #{turn_id}: no fallback sent: #{e.class}")
  end
end
