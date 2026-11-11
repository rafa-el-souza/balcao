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
#   followed by the line of any reservation the turn stored.
#
# The first reply of a conversation carries the demo notice (FR-01), in the
# language the reply is in, and the reply's language becomes the
# conversation's (FR-02). The reply is stored once, keyed by the turn
# (NFR-02), and sent to the conversation's stream; a turn that already has it
# is left alone. The budget gate and its modes join with FR-14 (PR-16); until
# then every turn runs in the normal mode.
class TurnProcessor
  MODE = "normal".freeze

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

  private

  # --- Commands -------------------------------------------------------------

  # FR-05: in the same run, the visitor's data goes, and the confirmation
  # goes to the stream, since there is no conversation left to store it in.
  # Nothing is traced: the trace would be deleted with the rest.
  def delete
    language = command_language
    @conversation.visitor.erase!
    broadcast(type: "deleted", text: FixedReply.command(:delete, language))
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

  # FR-12: the link to this conversation's trace page.
  def trace
    language = command_language
    url = "#{Rails.configuration.x.public_origin}/trace/#{@conversation.trace_token}"
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
    when :replied then [ result.text, "replied" ]
    when :refused then [ FixedReply.with_reservations(FixedReply.declined(language), reservations, language), "replied" ]
    else [ FixedReply.with_reservations(FixedReply.fallback(language), reservations, language), "failed" ]
    end
  end

  def reservations = Reservation.where(turn_id: @turn.id).includes(:product).order(:created_at, :id).to_a

  def finish(outcome, state, text, error: nil)
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

  def broadcast_reply(message)
    broadcast(type: "message", message: {
      id: message.id, conversation_id: message.conversation_id, turn_id: message.turn_id,
      author: message.author, body: message.body, created_at: message.created_at.iso8601(3)
    })
  end

  # On the stream of the turn's conversation, the one the visitor's page
  # follows; a reset's reply names the conversation it opened. A broadcast
  # that fails leaves the reply stored for the page to poll (FR-18).
  def broadcast(payload)
    ActionCable.server.broadcast("conversation:#{@conversation.id}", payload)
  rescue StandardError => e
    Rails.logger.error("turn #{@turn.id}: #{payload[:type]} not broadcast: #{e.class}")
  end

  # From the message's receipt to the reply (NFR-01).
  def latency_ms = ((Time.current - @inbound.created_at) * 1000).round
end
