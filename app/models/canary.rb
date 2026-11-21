# FR-17: the canary, a scheduled probe of the turn pipeline in the process
# (CanaryJob, every ten minutes, config/recurring.yml). It asks the
# attendant a visitor's question, as the fixed system visitor (Visitor.canary!)
# on its one conversation, through a visitor's turn: the visitors' own job,
# ProcessTurnJob, called in the canary's job (the conversation's lock, the
# job's attempts), the budget's gate, AgentRunner on the economy model
# whatever the month's mode (ADR-0003), FR-20's check and the stored reply,
# with no transport (the system visitor's conversation has no stream, and
# its channel no sender). No HTTP: the edge is the external monitor's, on
# /up (NFR-04).
#
# A run passes when the reply is stored within 20 seconds of the run's time,
# its job's enqueueing, the queue's wait included, and holds the marker the
# question elicits, the street of the store's
# address, which the system prompt carries (FR-03); or, when the demo is
# paused, when the reply is one of the pauses' fixed texts: the canary
# asserts "pipeline alive", not "model answered". Each run adds one to
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
# rather than queue behind a turn that may be stuck. The turn's job runs in
# the run's own thread, so the canary holds one of the worker's threads, as
# a visitor's turn does, and its verdict reads a turn its job finished
# (review finding C1 of pull request #64: the canary used to call the
# turn's processor alone, so a fault of the visitors' job, the lock among
# them, went unseen; the fix review's R3 and the owner, 2026-11-21: a turn
# run on the queue while the run waited held a second thread, and its
# reply could be read before its outcome was written).
class Canary
  # A visitor's question, in Portuguese, the conversation's language, whose
  # answer the system prompt holds, so the model needs no tool.
  QUESTION = "Qual é o endereço da farmácia?".freeze
  # FR-17's time for the reply, from the run's time to the reply's storage.
  WITHIN = 20.seconds

  # The visitors' own turns the run reads (review finding H1 of pull request
  # #64): the canary asks on the economy model, the visitors' normal mode
  # runs on another route, with its own model and fallback, so a fault of
  # that route alone shows only in their turns. Those that called the model
  # and ended in the last half hour, a few periods of the canary, since the
  # demo's visitors are few; at least two of them, every one ended by the
  # model's API failing (model_error), fail the run. A fallback a visitor's
  # own question causes, a reply cut at the turn's output limit, its tool
  # calls or its time, is no fault of the route, and anyone could send two
  # (the fix review's R1). Their outcomes alone: no word of theirs.
  VISITORS = 30.minutes
  VISITORS_AT_LEAST = 2
  # The latest of them read, enough to see that not every one failed.
  VISITORS_READ = 50
  # What the history calls a turn whose reply the model's call made or the
  # system wrote in its place after one (Turn::REPLY_KINDS): a pause, a
  # command and a turn's stored reservations called none.
  MODEL_KINDS = %w[model decline call_now refusal fallback].freeze

  Result = Data.define(:passed, :reason, :mode, :latency_ms)

  # Where an error broke a run, by the app's frames, which name only code,
  # as the nightly job's lines do (review finding H8 of pull request #64):
  # the run keeps no trace and its job no failed execution. Never the
  # error's message (threat model SR-30).
  def self.frames(error) = Rails.backtrace_cleaner.clean(Array(error.backtrace)).first(8).join("\n")

  # The street of the store's address, as the store sheet writes it (FR-26).
  def self.marker = StoreSheet.current.identity.fetch("address").split(",").first.strip

  # Whether a reply holds the street: its name after its kind ("dos
  # Boticários" of "Rua dos Boticários"), compared without case, accents,
  # Unicode's composition or extra spaces, and as whole words, so a reply
  # that writes "R." or leaves the accent out passes (review finding V4 of
  # pull request #64). A name shorter than SHORT after its kind ("A" of
  # "Rua A", "7") is matched with its kind, the whole street, since any text
  # holds a letter, the fallback's among them (the fix review's R4).
  SHORT = 4

  def self.marked?(text)
    street = folded(marker)
    name = street.split(" ", 2).last
    name = street if name.length < SHORT
    folded(text).match?(/(?<![[:alnum:]])#{Regexp.escape(name)}(?![[:alnum:]])/)
  end

  def self.folded(text) = I18n.transliterate(text.unicode_normalize(:nfc)).downcase.squish

  def initialize(heartbeat: Heartbeat.canary)
    @heartbeat = heartbeat
  end

  # due_at is when the run was due, its job's enqueueing: a visitor's 20
  # seconds start when the message arrives, before the queue's wait, and so
  # do the canary's, so a queue the visitors' turns hold fails it too
  # (review finding H6 of pull request #64).
  def run(due_at: nil)
    due_at ||= Time.current
    result = Rails.logger.tagged("canary") { probe(due_at) }
    result = count(with_visitors(result))
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
    judged(turn.reload, Message.find_by(turn_id: turn.id), due_at).tap { cleared(conversation) }
  rescue StandardError => e
    Rails.logger.error("canary: the run broke: #{e.class}\n#{self.class.frames(e)}")
    failed("the run broke: #{e.class}")
  end

  # The question, stored as a visitor's message is, and its turn run by the
  # visitors' own job in this thread (FR-17; C1 of #64, the fix review's
  # R3). A turn that breaks is left, as a visitor's is, to the job's next
  # attempt, which finds it deleted and does nothing.
  def ask(conversation)
    message = Message.record_inbound!(conversation:, external_id: "canary-#{SecureRandom.uuid}", body: QUESTION, source: "canary")
    Turn.for_inbound!(message).tap { |turn| ProcessTurnJob.perform_now(turn.id) }
  end

  # The run's rows go after its verdict; a deletion that breaks leaves them
  # for the next run to clear and never replaces the verdict (review finding
  # H11 of pull request #64).
  def cleared(conversation)
    clear(conversation)
  rescue StandardError => e
    Rails.logger.error("canary: the run's rows not deleted, #{e.class}; the next run clears them")
  end

  # Every message of the conversation is a run's; deleting them deletes their
  # turns, and with those the replies, the spans and the usage records (the
  # database's cascades, design §6.5).
  def clear(conversation) = Message.where(conversation_id: conversation.id).delete_all

  def judged(turn, reply, due_at)
    outcome = outcome_of(turn).presence || "not run"
    return failed("no reply, the turn is #{turn.state} (#{outcome})", turn) unless reply

    took = ((reply.created_at - due_at) * 1000).round
    text = reply.body_without_notice
    if turn.mode_paused?
      return failed("paused, and the reply is not a pause's text (outcome #{outcome})", turn) unless pause_texts(turn).include?(text)
    else
      return failed("the reply lacks the marker (outcome #{outcome})", turn) unless self.class.marked?(text)
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

  # A run that passed fails when the visitors' turns of the last half hour
  # that called the model all ended by the model's API failing, naming how
  # the latest ended; a read that breaks is the run's failure.
  def with_visitors(result)
    return result unless result.passed

    turns = Turn.joins(conversation: :visitor).where.not(visitors: { channel: "system" })
                .where(reply_kind: MODEL_KINDS, updated_at: VISITORS.ago..).order(updated_at: :desc, id: :desc).limit(VISITORS_READ).to_a
    return result if turns.size < VISITORS_AT_LEAST || turns.any? { |turn| turn.reply_kind != "fallback" }

    outcomes = turns.map { |turn| outcome_of(turn) }
    return result unless outcomes.all? { |outcome| outcome.start_with?("model_error") }

    failed("visitors' turns: #{turns.size} of #{turns.size} in the last #{VISITORS.in_minutes.to_i} minutes failed at the model's API " \
           "(outcome #{outcomes.first})")
  rescue StandardError => e
    failed("the visitors' turns not read: #{e.class}")
  end

  def pause_texts(turn)
    language = turn.conversation.language
    [ FixedReply.paused(language), FixedReply.daily_pause(language), FixedReply.forced_pause(language) ]
  end

  def failed(reason, turn = nil, took = nil) = Result.new(passed: false, reason:, mode: turn&.mode, latency_ms: took)

  # The day's count. One the database refused is lost from FR-13's uptime,
  # and the database's faults fail most runs too, so the run is told as a
  # failure (review finding H9 of pull request #64).
  def count(result)
    DailyAggregate.add!(kind: "canary", key: result.passed ? "passed" : "failed")
    result
  rescue StandardError => e
    Rails.logger.error("canary: the day's count not written, #{e.class}")
    result.passed ? failed("the day's count not written: #{e.class}") : result
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
