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
# conversation. The order holds for one break. A turn that breaks again
# inside a later turn's job is answered by its own next attempt, after the
# later reply; the later turn's model had its message in the history, so the
# visitor may read an answer to it twice (review findings R3 and V4 of pull
# request #18 and C1 of #11; accepted by the owner, 2026-11-15).
#
# A job run again for a turn that has its reply calls, bills and traces
# nothing (NFR-02).
#
# On Telegram (FR-19), after each turn the job answers, the visitor's stored
# replies still pending leave for the chat, oldest first (Telegram::Outbound),
# so an earlier turn's reply never waits for a later turn's model (review
# finding C1 of pull request #33); so does one a job stopped between storing
# and sending, when the job runs again. No send waits: a reply Telegram asks
# to wait for is tried again by TelegramReplyJob at its time.
#
# FR-05 on Telegram: the delete command's confirmation leaves before the
# deletion, and one that did not leave raises, so this job's attempts carry
# it; at the last the data goes whether or not it left (TurnProcessor, the
# owner, 2026-11-15). Until the data goes, the deletion holds the turns after
# it, whatever broke it (run_earlier), and a deletion or a turn it held that
# reaches the dead letter keeps no reply: the sweep or the next message runs
# the deletion again (review findings C3, H1 and R1 of pull request #41).
#
# A turn runs three times at most, whoever runs it (TurnProcessor::RUNS):
# a later turn's job, or NFR-03's sweep (StrandedSweepJob), that meets a turn
# run three times gives it the fallback instead (review findings of pull
# requests #11 and #18).
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

  # An earlier deletion in the conversation has not gone, so this job's turn
  # waits for the job's next attempt (run_earlier).
  class HeldByDeletion < StandardError; end

  queue_as :default

  retry_on StandardError, wait: :polynomially_longer, attempts: ATTEMPTS
  # Active Job raises the turn's error after these, unless one of them raises
  # its own; so the dead letter never raises (Active Job's run_after_discard_procs).
  after_discard { |_job, error| dead_letter(error) }

  def perform(turn_id)
    visitor_id = visitor_of(turn_id)
    attempt = TurnProcessor::Attempt.new(executions, ATTEMPTS, turn_id)
    under_lock(turn_id) do |turn|
      waiting_before(turn).each do |earlier|
        run_earlier(earlier.id, turn.conversation_id, attempt)
        deliver(visitor_id)
      end
      # An earlier turn may have been a deletion that took this one (FR-05),
      # or a reset that moved it.
      settled(turn) { |own| TurnProcessor.new(own, attempt:).call }
    end
    deliver(visitor_id)
  end

  private

  def visitor_of(turn_id) = Turn.where(id: turn_id).joins(:conversation).pick("conversations.visitor_id")

  # FR-19: the visitor's pending replies, to the chat; nothing for the web
  # or for a visitor a deletion took. A delivery that breaks (the database)
  # never fails a turn that is answered: one line, and TelegramReplyJob tries
  # again in a minute (review finding H8 of pull request #33).
  def deliver(visitor_id)
    visitor = visitor_id && Visitor.find_by(id: visitor_id)
    Telegram::Outbound.new.deliver_pending(visitor) if visitor
  rescue StandardError => e
    Rails.logger.error("telegram replies of visitor #{visitor_id}: not sent, #{e.class}")
    deliver_later(visitor_id)
  end

  def deliver_later(visitor_id)
    TelegramReplyJob.set(wait: 1.minute).perform_later(visitor_id)
  rescue StandardError => e
    Rails.logger.error("telegram replies of visitor #{visitor_id}: not tried again, #{e.class}")
  end

  # Yields the turn under its conversation's lock, unless it is gone or has
  # its reply. When the block answers :moved, a reset moved the turn into the
  # conversation it opened while this job waited, and the turn is yielded
  # again under that conversation's lock: a turn runs only under the lock of
  # the conversation it belongs to (review finding R1 of pull request #11).
  #
  # Every line logged under the lock carries the conversation's id (NFR-05).
  def under_lock(turn_id)
    loop do
      turn = Turn.find_by(id: turn_id)
      return if turn.nil? || Message.exists?(turn_id:)

      held = Rails.logger.tagged("conversation_id=#{turn.conversation_id}") do
        ConversationLock.hold(turn.conversation_id) { yield turn }
      end
      return unless held == :moved
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
  #
  # A deletion that did not go is the exception, whatever broke it (its
  # confirmation that did not leave, or the deletion itself after the
  # confirmation left): it holds the turns after it, so this job raises and
  # its own turn waits for the job's next attempt, and no message sent after a
  # request to delete reaches the model, nor a reset that would move the later
  # turns out from under the deletion's lock (FR-05, FR-19; review finding C1,
  # the verifier's V1 and the fix review's R1 of pull request #41). The
  # deletion runs with this job's attempt, so at this job's last it goes
  # whether or not its confirmation left, and takes this job's turn with the
  # rest.
  def run_earlier(turn_id, conversation_id, attempt)
    turn = Turn.find_by(id: turn_id)
    return if turn.nil? || turn.conversation_id != conversation_id

    processor = TurnProcessor.new(turn, attempt:)
    processor.call
  rescue StandardError => e
    raise held(turn_id, e) if processor&.deletion?

    Rails.logger.error("earlier turn #{turn_id} failed: #{e.class}")
  end

  def held(turn_id, error)
    Rails.logger.error("earlier turn #{turn_id}: a deletion that did not go holds the turns after it, #{error.class}")
    HeldByDeletion.new("an earlier deletion did not go; the job tries this turn again")
  end

  # The job's last attempt failed (NFR-03). The line names the job, which
  # Solid Queue keeps as a failed execution, the turn and the error by its
  # class alone, never its message, which may quote what the visitor wrote
  # (SR-30). Then the visitor gets the fallback, under the conversation's
  # lock like any reply of the turn; a deletion, or a turn an earlier
  # deletion held, keeps no reply, with a line, so the sweep or the next
  # message runs the deletion again (TurnProcessor#give_up).
  def dead_letter(error)
    turn_id = arguments.first
    Rails.logger.error("dead letter: #{self.class} #{job_id}, turn #{turn_id}, #{executions} attempts, #{error.class}")
    visitor_id = visitor_of(turn_id)
    if error.is_a?(HeldByDeletion)
      Rails.logger.error("dead letter: turn #{turn_id} is held by an earlier deletion: no reply, " \
                         "the sweep or the next message runs the deletion again")
    else
      under_lock(turn_id) { |turn| settled(turn) { |own| TurnProcessor.new(own).give_up(error) } }
    end
    deliver(visitor_id)
  rescue StandardError => e
    Rails.logger.error("dead letter: turn #{turn_id}: no fallback sent: #{e.class}")
  end
end
