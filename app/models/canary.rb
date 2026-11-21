# FR-17: the canary, a scheduled probe of the turn pipeline in the process
# (CanaryJob, every ten minutes, config/recurring.yml). It asks the
# attendant a visitor's question, as the fixed system visitor (Visitor.canary!)
# on its one conversation, through a visitor's turn: the budget's gate,
# AgentRunner on the economy model whatever the month's mode (ADR-0003),
# FR-20's check and the stored reply, with no transport (the system visitor's
# conversation has no stream, and its channel no sender). No HTTP: the edge
# is the external monitor's, on /up (NFR-04).
#
# A run passes when the reply is stored within 20 seconds of the question
# and holds the marker the question elicits, the street of the store's
# address, which the system prompt carries (FR-03); or, when the demo is
# paused, when the reply is one of the pauses' fixed texts: the canary
# asserts "pipeline alive", not "model answered". Each run adds one to the
# day's passed or failed count (DailyAggregate, which FR-13's pipeline uptime
# reads) and tells the external monitor through its heartbeat (Heartbeat):
# all is well, or a failure with its reason, which names an outcome, a time
# or an error's class, never a word of a reply (threat model SR-30). Its model
# calls are charged to the month as any turn's (FR-14), about 144 runs a day.
#
# The run keeps nothing but the conversation and the count: it deletes its
# question, and with it the turn, its reply, its spans and its usage records
# (the month's spend stays on the budget's row), so the model never reads a
# history and the conversation never grows; and it first clears what a run
# that broke or was killed left. It holds the conversation's lock while it
# runs, tried without waiting: a run that finds an earlier one still holding
# it fails at once, rather than queue behind a run that may be stuck.
class Canary
  # A visitor's question, in Portuguese, the conversation's language, whose
  # answer the system prompt holds, so the model needs no tool.
  QUESTION = "Qual é o endereço da farmácia?".freeze
  # FR-17's time for the reply, from the question's storage to the reply's.
  WITHIN = 20.seconds

  Result = Data.define(:passed, :reason, :mode, :latency_ms)

  # The street of the store's address, as the store sheet writes it (FR-26).
  def self.marker = StoreSheet.current.identity.fetch("address").split(",").first.strip

  def initialize(heartbeat: Heartbeat.canary)
    @heartbeat = heartbeat
  end

  def run
    result = Rails.logger.tagged("canary") { probe }
    count(result)
    tell(result)
    result
  end

  private

  def probe
    conversation = Conversation.current_for!(Visitor.canary!)
    held = AdvisoryLock.try_hold("conversation:#{conversation.id}") do
      clear(conversation)
      ask(conversation)
    ensure
      clear(conversation)
    end
    held || failed("an earlier run still holds the canary's conversation")
  rescue StandardError => e
    failed("the run broke: #{e.class}")
  end

  def ask(conversation)
    message = Message.record_inbound!(conversation:, external_id: "canary-#{SecureRandom.uuid}", body: QUESTION, source: "canary")
    turn = Turn.for_inbound!(message)
    TurnProcessor.new(turn).call
    judged(turn.reload)
  end

  # Every message of the conversation is a run's; deleting them deletes their
  # turns, and with those the replies, the spans and the usage records (the
  # database's cascades, design §6.5).
  def clear(conversation) = Message.where(conversation_id: conversation.id).delete_all

  def judged(turn)
    outcome = outcome_of(turn)
    reply = turn.outbound_message or return failed("no reply, the turn is #{turn.state} (#{outcome})", turn)
    text = reply.body_without_notice
    if turn.mode_paused?
      return failed("paused, and the reply is not a pause's text (outcome #{outcome})", turn) unless pause_texts(turn).include?(text)
    else
      return failed("the reply lacks the marker (outcome #{outcome})", turn) unless text.include?(self.class.marker)
    end
    return failed("the reply took #{turn.latency_ms} ms, over #{WITHIN.in_milliseconds}", turn) if turn.latency_ms.to_i > WITHIN.in_milliseconds

    Result.new(passed: true, reason: nil, mode: turn.mode, latency_ms: turn.latency_ms)
  end

  # The turn's outcome and the error's class its root span names, read
  # before the run deletes the spans, the only place the class was (review
  # finding H2 of pull request #64): a class names no visitor (SR-30).
  def outcome_of(turn)
    root = TraceEvent.where(turn_id: turn.id, name: "balcao.turn").order(:started_at).last&.span_attributes || {}
    root.values_at("balcao.turn.outcome", "error.type").compact.join(", ")
  end

  def pause_texts(turn)
    language = turn.conversation.language
    [ FixedReply.paused(language), FixedReply.daily_pause(language), FixedReply.forced_pause(language) ]
  end

  def failed(reason, turn = nil) = Result.new(passed: false, reason:, mode: turn&.mode, latency_ms: turn&.latency_ms)

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
