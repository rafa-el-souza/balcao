# One turn, from its inbound message to its one reply (design §6.3), run by
# ProcessTurnJob under the conversation's lock:
#
# - a command is answered before the model is called, so no model output and
#   no prompt injection can trigger one (FR-04 reset, FR-05 delete, FR-12
#   trace); its trace is the command's span alone;
# - a turn whose reservation an earlier run stored is answered with the
#   reservation's fixed line, never through the model again, which could
#   reserve another product (NFR-02);
# - a turn of a month the budget paused, at its cap or by the operator's
#   hand, is answered with the pause's fixed reply, and no model is called
#   (FR-14, threat model SR-02); the budget's mode is read here, before any
#   model call, and names the route of the turn's model (ModelPolicy);
# - anything else goes through AgentRunner, whose events become the turn's
#   spans (FR-12), and its outcome becomes the reply: the model's text, FR-09's
#   decline for a refusal (SR-19) or the fallback (NFR-03), the last two
#   followed by the line of any reservation the turn stored, and the first by
#   the line of a reservation whose code or pickup time it left out and, when
#   the cap of open reservations refused one, by the lines of those the
#   visitor holds (FR-07). Before those lines come the fixed lines the model's
#   tags ask for, the emergency line or the offer of the pharmacist, and the
#   offer after a decline (FR-09, FR-10's MVP note);
# - a turn the job gave up on after its attempts gets the fallback too
#   (give_up, NFR-03).
#
# Every way a turn ends is an outcome on its root span, which the glass box
# words (web/src/locales, instrument.outcomes): OUTCOMES. The root also carries
# the mode the turn ran in and the month's mode when it closed, after its own
# charge, which the glass box's head follows (FR-14; review finding C3 of pull
# request #29). A slice that adds or
# renames one gives the panel its words in the same change (design §10, note
# of 2026-11-12); spec/models/turn_outcomes_spec.rb holds the two together.
#
# The first reply of a conversation carries the demo notice (FR-01), in the
# language the reply is in, and the reply's language becomes the
# conversation's (FR-02). The reply is stored once, keyed by the turn
# (NFR-02), and sent to the conversation's stream; a turn that already has it
# is left alone.
#
# Every model call the turn makes is charged to the month (Budget) as its
# answer arrives, so a run that breaks later, or a worker a deploy stops
# mid-turn, keeps the charge of each call it made: they were paid for (FR-14;
# review finding V3 of pull request #29: a transaction left for the end of the
# run is rolled back when its thread is killed).
class TurnProcessor
  # AgentRunner's, then the three this class adds: a turn answered from its
  # stored reservations without the model, one the budget paused and one the
  # job gave up on.
  OUTCOMES = [ *AgentRunner::OUTCOMES.map(&:to_s), "reservations", "paused", "dead_letter" ].freeze

  def initialize(turn, commands: CommandPhrases.current)
    @turn = turn
    @conversation = turn.conversation
    @inbound = turn.inbound_message
    @commands = commands
  end

  def call
    return if Message.exists?(turn_id: @turn.id)

    command = @commands.match(@inbound.body)
    TraceRecorder.close_interrupted(@turn)
    @recorder = TraceRecorder.new(@turn)
    case command
    when :delete then delete
    when :reset then reset
    when :trace then trace
    else answer
    end
  end

  # NFR-03: the job's last attempt failed (ProcessTurnJob's dead letter), so
  # the turn is answered with the fallback, followed by the line of any
  # reservation it stored (NFR-02), rather than left waiting for good. It is a
  # run of its own in the trace, with no model call: the root from the
  # message's receipt, the reply, the outcome dead_letter and the error's
  # class.
  def give_up(error)
    return if Message.exists?(turn_id: @turn.id)

    TraceRecorder.close_interrupted(@turn)
    @recorder = TraceRecorder.new(@turn)
    @root = @recorder.start_span("balcao.turn", started_at: @inbound.created_at, attributes: {
      "balcao.channel" => @inbound.channel, "balcao.message.source" => @inbound.source
    })
    language = @conversation.language
    finish("dead_letter", "failed", FixedReply.with_reservations(FixedReply.fallback(language), reservations, language), error:)
  rescue StandardError => e
    @recorder&.abandon(e.class.name)
    raise
  end

  private

  # --- Commands -------------------------------------------------------------

  # FR-05: in the same run, the visitor's data goes, and the confirmation
  # goes to the stream, since there is no conversation left to store it in.
  # Nothing is traced: the trace would be deleted with the rest. A trace page
  # open on any of the visitor's conversations is told too, so it drops what
  # it showed (review finding G2 of pull request #17).
  def delete
    language = command_language
    visitor = @conversation.visitor
    tokens = visitor.conversations.pluck(:trace_token)
    visitor.erase!
    broadcast(type: "deleted", text: FixedReply.command(:delete, language))
    tokens.each { |token| broadcast({ type: "deleted" }, "trace:#{token}") }
  end

  # FR-04: the conversation closes and the reply opens the next one, so its
  # confirmation carries the notice.
  #
  # The intake puts a message in the open conversation when it arrives, so a
  # message sent while this reset waited its turn sits in the conversation
  # the reset closes. It was sent after the reset: it moves, with its turn, to
  # the conversation the reset opens, and its model never reads what came
  # before (review findings V1 and R2 of pull request #11); a second reset
  # among those messages starts over again in its turn. One transaction
  # closes, opens, moves and confirms, so a moved turn's job, which runs it
  # under the new conversation's lock (ProcessTurnJob), finds the
  # confirmation already there and gives no second notice.
  def reset
    language = command_language
    command(:reset) do
      message = ApplicationRecord.transaction do
        @conversation.update!(closed_at: Time.current) if @conversation.closed_at.nil?
        current = Conversation.current_for!(@conversation.visitor)
        current.update!(language:) unless current.messages.outbound.exists?
        move_later_turns(current)
        record_reply(FixedReply.command(:reset, language), conversation: current, language:)
      end
      broadcast_reply(message)
    end
  end

  # The turns after this one with no reply yet, and their messages. They have
  # not run: turns run in arrival order under this conversation's lock, which
  # this run holds. update_all writes conversation_id alone, on purpose.
  def move_later_turns(current)
    later = Turn.where(conversation_id: @conversation.id)
                .where("(turns.created_at, turns.id) > (?, ?)", @turn.created_at, @turn.id)
                .where.missing(:outbound_message).pluck(:id, :inbound_message_id)
    return if later.empty?

    Turn.where(id: later.map(&:first)).update_all(conversation_id: current.id, updated_at: Time.current)
    Message.where(id: later.map(&:last)).update_all(conversation_id: current.id, updated_at: Time.current)
  end

  # FR-12: the link to this conversation's trace page. The token follows the
  # "#", which no browser sends, so no request line carries it, in Rails' log
  # or in kamal-proxy's (review finding V3 of pull request #17, SR-30).
  def trace
    language = command_language
    url = "#{Rails.configuration.x.public_origin}/trace##{@conversation.trace_token}"
    command(:trace) { store_reply(FixedReply.command(:trace, language, url:), language:) }
  end

  def command(name)
    @inbound.update_columns(source: "command")
    span = @recorder.start_span("balcao.command", attributes: { "balcao.command.name" => name.to_s })
    yield
    @turn.update!(state: "replied", latency_ms:)
  ensure
    span&.finish
  end

  # The language of a phrase only one language lists ("start over"), else
  # the conversation's ("/reiniciar" is Portuguese and Spanish).
  def command_language
    languages = @commands.languages(@inbound.body)
    languages.one? ? AgentRunner::LANGUAGES.fetch(languages.first) : @conversation.language
  end

  # --- The model --------------------------------------------------------------

  def answer
    @turn.update!(state: "running")
    @root = @recorder.start_span("balcao.turn", started_at: @inbound.created_at, attributes: {
      "balcao.channel" => @inbound.channel, "balcao.message.source" => @inbound.source
    })
    stored = reservations
    return finish("reservations", "replied", FixedReply.reservations(stored, @conversation.language)) if stored.any?

    mode = Budget.mode
    return paused if mode == "paused"

    run_model(mode)
  rescue StandardError => e
    broken(e)
    raise
  end

  # FR-14: the month is paused, so the reply is the pause's, with no model;
  # a model an earlier run of the turn named is no longer the turn's.
  def paused
    @turn.update!(mode: "paused", model: nil)
    @root.attributes["balcao.turn.mode"] = "paused"
    finish("paused", "replied", FixedReply.paused(@conversation.language))
  end

  def run_model(mode)
    @turn.update!(mode:, model: ModelPolicy.route(mode).model)
    @root.attributes["balcao.turn.mode"] = mode
    events = TurnTrace.new(@recorder, @root)
    result = AgentRunner.new.run(@turn, mode:) do |event|
      Budget.charge!(@turn, event.usage) if event.is_a?(AgentRunner::ModelCall)
      events.on(event)
    end
    @conversation.update!(language: result.language) if result.language
    text, state = reply_of(result)
    finish(result.outcome, state, text, error: result.error)
  end

  def reply_of(result)
    language = @conversation.language
    case result.outcome
    when :replied then [ with_facts(result, language), "replied" ]
    when :refused then [ FixedReply.with_reservations(with_lines(FixedReply.declined(language), language, offer: true),
                                                      reservations, language), "replied" ]
    else [ FixedReply.with_reservations(FixedReply.fallback(language), reservations, language), "failed" ]
    end
  end

  def reservations = Reservation.where(turn_id: @turn.id).includes(:product).order(:created_at, :id).to_a

  # FR-07: the reply carries each reservation's code and pickup deadline. The
  # model is told to write them; a reply that leaves out a reservation's code
  # or its deadline is followed by that reservation's line, as the fallback
  # is (review finding C1 of pull request #19), so the visitor always learns
  # the code, and the next turn's model reads it in the history. When the cap
  # of open reservations refused one, the ones the visitor holds are listed
  # the same way, which the refusal leaves to the system, since they may be
  # another conversation's (findings C5 and N1 of the same review).
  def with_facts(result, language)
    text = result.text
    facts = reservations
    facts |= held_reservations if result.tool_calls.any? { |call| call.refusal == "open_limit" }
    reply = with_lines(text, language, offer: result.offer, emergency: result.emergency)
    FixedReply.with_reservations(reply, facts.reject { |reservation| written?(text, reservation) }, language)
  end

  # FR-09 and FR-10's MVP note, with the owner's decisions of 2026-11-14: the
  # emergency line comes alone, since an emergency's one instruction is to call
  # for help, and in every reply that asks for it; the offer of the pharmacist
  # is left out when the conversation's last reply carried it in this
  # language, as a person at the counter gives the phone once, unless the
  # reply has nothing else to say (review finding C1 of pull request #27).
  def with_lines(text, language, offer:, emergency: false)
    return FixedReply.with_emergency(text, language) if emergency
    return text unless offer && (text.blank? || !offered_last?(language))

    FixedReply.with_offer(text, language)
  end

  # This turn's reply is not stored yet, so the last one is the turn before's.
  def offered_last?(language)
    last = @conversation.messages.outbound.order(created_at: :desc, id: :desc).first
    last.present? && last.body.include?(FixedReply.offer(language))
  end

  # The reply writes the reservation's code and its deadline: the day as
  # day/month and the time as HH:MM, as the description asks. The time alone
  # is not the deadline, since every weekday closes at the same hour, and a
  # day named without its date ("amanhã", "segunda") cannot be told right
  # from wrong, so such a reply gets the line too (finding R1 of the same
  # review).
  def written?(text, reservation)
    pickup = reservation.pickup_until.in_time_zone
    text.include?(reservation.code) && text.include?(pickup.strftime("%H:%M")) &&
      text.match?(%r{(?<!\d)0?#{pickup.day}/0?#{pickup.month}(?!\d)})
  end

  def held_reservations
    Reservation.held_by(@conversation.visitor).includes(:product).order(:created_at, :id).to_a
  end

  def finish(outcome, state, text, error: nil)
    raise ArgumentError, "#{outcome} is not in TurnProcessor::OUTCOMES" unless OUTCOMES.include?(outcome.to_s)

    outbound = @recorder.start_span("balcao.outbound", parent: @root, attributes: { "balcao.message.author" => "bot" })
    message = store_reply(text, language: @conversation.language)
    outbound.finish(attributes: { "balcao.message.characters" => message.body.length })
    @turn.update!(state:, latency_ms:)
    @root.finish(attributes: { "balcao.turn.mode" => @root.attributes["balcao.turn.mode"],
                               "balcao.turn.outcome" => outcome.to_s, "error.type" => error&.class&.name,
                               "balcao.budget.mode" => month_mode })
  end

  # The month's mode as the turn closes; none when it cannot be read, since
  # the reply is stored and only the head's word would be missing.
  def month_mode
    Budget.mode
  rescue StandardError => e
    Rails.logger.error("turn #{@turn.id}: the month's mode not read: #{e.class}")
    nil
  end

  # A turn that broke outside the model (the database, a bug): its spans are
  # closed with the error and it is marked failed, for the job's retry.
  def broken(error)
    @recorder.abandon(error.class.name)
    @turn.update_columns(state: "failed")
  rescue StandardError => e
    Rails.logger.error("turn #{@turn.id} not marked failed: #{e.class}")
  end

  # --- The reply --------------------------------------------------------------

  def store_reply(text, language:, conversation: @conversation)
    message = record_reply(text, conversation:, language:)
    broadcast_reply(message)
    message
  end

  def record_reply(text, conversation:, language:)
    body = conversation.messages.outbound.exists? ? text : FixedReply.with_notice(text, language)
    Message.record_outbound!(turn: @turn, body:, conversation:)
  end

  def broadcast_reply(message)
    codes = Reservation.where(visitor_id: @conversation.visitor_id).pluck(:code)
    broadcast(type: "message", message: message.stream_payload(reservation_codes: codes))
  end

  # On the stream of the turn's conversation, the one the visitor's page
  # follows; a reset's reply names the conversation it opened. A broadcast
  # that fails leaves the reply stored for the page to poll (FR-18).
  def broadcast(payload, stream = "conversation:#{@conversation.id}")
    ActionCable.server.broadcast(stream, payload)
  rescue StandardError => e
    Rails.logger.error("turn #{@turn.id}: #{payload[:type]} not broadcast: #{e.class}")
  end

  # From the message's receipt to the reply (NFR-01).
  def latency_ms = ((Time.current - @inbound.created_at) * 1000).round
end
