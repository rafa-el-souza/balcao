# One turn, from its inbound message to its one reply (design §6.3), run by
# ProcessTurnJob under the conversation's lock:
#
# - a command is answered before the model is called, so no model output and
#   no prompt injection can trigger one (FR-04 reset, FR-05 delete, FR-12
#   trace); its trace is the command's span alone;
# - a turn whose reservation an earlier run stored is answered with the
#   reservation's fixed line, never through the model again, which could
#   reserve another product (NFR-02);
# - anything else goes through AgentRunner, whose events become the turn's
#   spans (FR-12), and its outcome becomes the reply: the model's text, the
#   refusal's fixed text (SR-19) or the fallback (NFR-03), the last two
#   followed by the line of any reservation the turn stored, and the first by
#   the line of a reservation whose code or pickup time it left out (FR-07);
# - a turn the job gave up on after its attempts gets the fallback too
#   (give_up, NFR-03).
#
# Every way a turn ends is an outcome on its root span, which the glass box
# words (web/src/locales, instrument.outcomes): OUTCOMES. A slice that adds or
# renames one gives the panel its words in the same change (design §10, note
# of 2026-11-12); spec/models/turn_outcomes_spec.rb holds the two together.
#
# The first reply of a conversation carries the demo notice (FR-01), in the
# language the reply is in, and the reply's language becomes the
# conversation's (FR-02). The reply is stored once, keyed by the turn
# (NFR-02), and sent to the conversation's stream; a turn that already has it
# is left alone. The budget gate and its modes join with FR-14 (PR-16); until
# then every turn runs in the normal mode.
class TurnProcessor
  MODE = "normal".freeze
  # AgentRunner's, then the two this class adds: a turn answered from its
  # stored reservations without the model, and one the job gave up on.
  OUTCOMES = [ *AgentRunner::OUTCOMES.map(&:to_s), "reservations", "dead_letter" ].freeze

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

    run_model
  rescue StandardError => e
    broken(e)
    raise
  end

  def run_model
    @turn.update!(mode: MODE, model: ModelPolicy.route(MODE).model)
    @root.attributes["balcao.turn.mode"] = MODE
    events = TurnTrace.new(@recorder, @root)
    result = AgentRunner.new.run(@turn, mode: MODE) { |event| events.on(event) }
    @conversation.update!(language: result.language) if result.language
    text, state = reply_of(result)
    finish(result.outcome, state, text, error: result.error)
  end

  def reply_of(result)
    language = @conversation.language
    case result.outcome
    when :replied then [ with_facts(result.text, language), "replied" ]
    when :refused then [ FixedReply.with_reservations(FixedReply.declined(language), reservations, language), "replied" ]
    else [ FixedReply.with_reservations(FixedReply.fallback(language), reservations, language), "failed" ]
    end
  end

  def reservations = Reservation.where(turn_id: @turn.id).includes(:product).order(:created_at, :id).to_a

  # FR-07: the reply carries each reservation's code and pickup deadline. The
  # model is told to write them; a reply that leaves out a reservation's code
  # or its pickup time (HH:MM, as the prompt has times written) is followed by
  # that reservation's line, as the fallback is (review finding C1 of pull
  # request #19), so the visitor always learns the code, and the next turn's
  # model reads it in the history.
  def with_facts(text, language)
    missing = reservations.reject do |reservation|
      text.include?(reservation.code) && text.include?(reservation.pickup_until.in_time_zone.strftime("%H:%M"))
    end
    FixedReply.with_reservations(text, missing, language)
  end

  def finish(outcome, state, text, error: nil)
    raise ArgumentError, "#{outcome} is not in TurnProcessor::OUTCOMES" unless OUTCOMES.include?(outcome.to_s)

    outbound = @recorder.start_span("balcao.outbound", parent: @root, attributes: { "balcao.message.author" => "bot" })
    message = store_reply(text, language: @conversation.language)
    outbound.finish(attributes: { "balcao.message.characters" => message.body.length })
    @turn.update!(state:, latency_ms:)
    @root.finish(attributes: { "balcao.turn.mode" => @root.attributes["balcao.turn.mode"],
                               "balcao.turn.outcome" => outcome.to_s, "error.type" => error&.class&.name })
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

  def broadcast_reply(message) = broadcast(type: "message", message: message.stream_payload)

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
