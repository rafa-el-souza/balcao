# FR-17: the canary, a scheduled probe of the turn pipeline in the process
# (CanaryJob, every ten minutes, config/recurring.yml). It asks the
# attendant a visitor's question, as the fixed system visitor (Visitor.canary!)
# on its one conversation, through a visitor's turn: its ProcessTurnJob on
# the queue (the conversation's lock, the job's attempts and dead letter),
# the budget's gate, AgentRunner on the economy model whatever the month's
# mode (ADR-0003), FR-20's check and the stored reply, with no transport
# (the system visitor's conversation has no stream, and its channel no
# sender). No HTTP: the edge is the external monitor's, on /up (NFR-04).
#
# A run passes when the reply is stored within 20 seconds of the run's time,
# its job's enqueueing, the queue's wait included, and holds the marker the
# question elicits, the street of the store's
# address, which the system prompt carries (FR-03); or, when the demo is
# paused, when the reply is one of the pauses' fixed texts: the canary
# asserts "pipeline alive", not "model answered". It waits for the reply as
# a visitor's page would, looking every half second. Each run adds one to
# the day's passed or failed count (DailyAggregate, which FR-13's pipeline
# uptime reads) and tells the external monitor through its heartbeat
# (Heartbeat): all is well, or a failure with its reason, which names an
# outcome, a time or an error's class, never a word of a reply (threat model
# SR-30). Its model calls are charged to the month as any turn's (FR-14),
# about 144 runs a day.
#
# The run keeps nothing but the conversation and the count: it deletes its
# question, and with it the turn, its reply, its spans and its usage records
# (the month's spend stays on the budget's row), so the model never reads a
# history and the conversation never grows; and it first clears what an
# earlier run left. It reads the conversation's lock without taking it: a
# run that finds an earlier run's turn still at work under it fails at once,
# rather than queue behind a turn that may be stuck, and a turn whose job
# still holds the lock once the run is judged keeps its rows for the next
# run to clear (review finding C1 of pull request #64: the canary used to
# call the turn's processor in its own job, so a fault of the visitors' job,
# the lock among them, went unseen).
class Canary
  # A visitor's question, in Portuguese, the conversation's language, whose
  # answer the system prompt holds, so the model needs no tool.
  QUESTION = "Qual é o endereço da farmácia?".freeze
  # FR-17's time for the reply, from the question's storage to the reply's.
  WITHIN = 20.seconds
  # How often the run looks for the reply while the turn's job works.
  POLL = 0.5
  # How long a judged run waits for the turn's job to let go of the
  # conversation before it deletes the rows: the job stores the reply under
  # the lock and lets go of it right after.
  SETTLE = 5.seconds

  Result = Data.define(:passed, :reason, :mode, :latency_ms)

  # The street of the store's address, as the store sheet writes it (FR-26).
  def self.marker = StoreSheet.current.identity.fetch("address").split(",").first.strip

  def initialize(heartbeat: Heartbeat.canary, sleeper: ->(seconds) { sleep(seconds) })
    @heartbeat = heartbeat
    @sleeper = sleeper
  end

  # due_at is when the run was due, its job's enqueueing: a visitor's 20
  # seconds start when the message arrives, before the queue's wait, and so
  # do the canary's, so a queue the visitors' turns hold fails it too
  # (review finding H6 of pull request #64).
  def run(due_at: nil)
    due_at ||= Time.current
    result = Rails.logger.tagged("canary") { probe(due_at) }
    count(result)
    tell(result)
    result
  end

  private

  def probe(due_at)
    late = Time.current - due_at
    return failed("the run started #{late.round} s after its time, over #{WITHIN.to_i} s") if late > WITHIN

    conversation = Conversation.current_for!(Visitor.canary!)
    lock = "conversation:#{conversation.id}"
    return failed("an earlier run's turn still holds the canary's conversation") unless AdvisoryLock.free?(lock)

    clear(conversation)
    turn = ask(conversation)
    reply = awaited(turn, due_at + WITHIN)
    judged(turn.reload, reply, due_at).tap { settled(conversation, lock) }
  rescue StandardError => e
    failed("the run broke: #{e.class}")
  end

  # The question, stored as a visitor's message is, and its turn's job on
  # the queue, as Intake leaves it (FR-17; C1 of #64).
  def ask(conversation)
    message = Message.record_inbound!(conversation:, external_id: "canary-#{SecureRandom.uuid}", body: QUESTION, source: "canary")
    Turn.for_inbound!(message).tap { |turn| ProcessTurnJob.perform_later(turn.id) }
  end

  # The turn's reply once its job stored it, or nil at the deadline.
  def awaited(turn, deadline)
    loop do
      reply = Message.find_by(turn_id: turn.id)
      return reply if reply
      return if Time.current >= deadline

      @sleeper.call(POLL)
    end
  end

  # The rows go once the turn's job let go of the conversation; a job that
  # still holds it keeps them, for the next run to clear.
  def settled(conversation, lock)
    deadline = Time.current + SETTLE
    @sleeper.call(POLL) until (free = AdvisoryLock.free?(lock)) || Time.current >= deadline
    return clear(conversation) if free

    Rails.logger.info("canary: the turn's job still holds the conversation; the next run clears its rows")
  end

  # Every message of the conversation is a run's; deleting them deletes their
  # turns, and with those the replies, the spans and the usage records (the
  # database's cascades, design §6.5).
  def clear(conversation) = Message.where(conversation_id: conversation.id).delete_all

  def judged(turn, reply, due_at)
    outcome = outcome_of(turn).presence || "not run"
    return failed("no reply within #{WITHIN.to_i} s, the turn is #{turn.state} (#{outcome})", turn) unless reply

    took = ((reply.created_at - due_at) * 1000).round
    text = reply.body_without_notice
    if turn.mode_paused?
      return failed("paused, and the reply is not a pause's text (outcome #{outcome})", turn) unless pause_texts(turn).include?(text)
    else
      return failed("the reply lacks the marker (outcome #{outcome})", turn) unless text.include?(self.class.marker)
    end
    return failed("the reply took #{took} ms from the run's time, over #{WITHIN.in_milliseconds}", turn, took) if took > WITHIN.in_milliseconds

    Result.new(passed: true, reason: nil, mode: turn.mode, latency_ms: took)
  end

  # The turn's outcome and the error's class the root span of its last run
  # names, read before the run deletes the spans, the only place the class
  # was (review finding H2 of pull request #64): a class names no visitor
  # (SR-30). Every run's root starts at the question's receipt, so the last
  # is the last written.
  def outcome_of(turn)
    root = TraceEvent.where(turn_id: turn.id, name: "balcao.turn").order(:created_at, :id).last&.span_attributes || {}
    root.values_at("balcao.turn.outcome", "error.type").compact.join(", ")
  end

  def pause_texts(turn)
    language = turn.conversation.language
    [ FixedReply.paused(language), FixedReply.daily_pause(language), FixedReply.forced_pause(language) ]
  end

  def failed(reason, turn = nil, took = nil) = Result.new(passed: false, reason:, mode: turn&.mode, latency_ms: took)

  # The day's count; one that cannot be written is a line, and the monitor
  # is told all the same.
  def count(result)
    DailyAggregate.add!(kind: "canary", key: result.passed ? "passed" : "failed")
  rescue StandardError => e
    Rails.logger.error("canary: the day's count not written, #{e.class}")
  end

  def tell(result)
    if result.passed
      Rails.logger.info("canary: passed in #{result.latency_ms} ms (mode #{result.mode})")
      @heartbeat.beat
    else
      Rails.logger.error("canary: failed: #{result.reason}")
      @heartbeat.failure("canary: #{result.reason}")
    end
  end
end
