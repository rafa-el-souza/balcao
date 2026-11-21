# One turn, from its inbound message to its one reply (design §6.3), run by
# ProcessTurnJob under the conversation's lock:
#
# - a command is answered before the model is called, so no model output and
#   no prompt injection can trigger one (FR-04 reset, FR-05 delete, FR-12
#   trace, FR-19 start and help); its trace is the command's span alone;
# - a turn whose reservation an earlier run stored is answered with the
#   reservation's fixed line, never through the model again, which could
#   reserve another product (NFR-02);
# - a turn the budget paused, at the month's cap, at an economy the eval
#   run has not allowed (the month's or the day's), or by the operator's
#   hand, is answered with that pause's fixed reply, and no model is called
#   (FR-14, threat model SR-02); the budget's mode is read here, before any
#   model call, and names the route of the turn's model (ModelPolicy), the
#   economy model's from 70 % of the cap and from the day's slice on, and
#   always the economy model's for FR-17's canary, whose question a fixed
#   system visitor asks on a conversation no page follows (canary?);
# - anything else goes through AgentRunner, whose events become the turn's
#   spans (FR-12), and its outcome becomes the reply: the model's text, FR-09's
#   decline for a refusal (SR-19) or the fallback (NFR-03), the last two
#   followed by the line of any reservation the turn stored, and the first by
#   the line of a reservation whose code or pickup time it left out and, when
#   the cap of open reservations refused one, by the lines of those the
#   visitor holds (FR-07). Before those lines come the fixed lines the model's
#   tags ask for, the emergency line or the offer of the pharmacist (FR-09,
#   FR-10's MVP note), and the emergency line after a refusal's decline: a
#   refused message is the one the system cannot read, so it may be a call
#   for help (FR-09, the owner, 2026-11-15);
# - the text the model wrote passes FR-20's check (Guardrail) before any of
#   that, and a text it finds clinical is replaced by FR-09's decline and the
#   facts the turn's tools produced, or by the call to call now in an
#   emergency (replaced); a check that gives no verdict lets the text go,
#   traced and logged (threat model R4), unless the turn's edge cut it;
# - the model's steps and the check run inside the turn's edge (TurnEdge,
#   threat model SR-20), set when the model's work starts: sixty seconds, or
#   FR-17's canary's twenty, so a slow model ends a canary's turn at the
#   canary's own time; past it the turn ends at its deadline with the
#   fallback, a reply the edge left unchecked among them;
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
# is left alone. On Telegram, ProcessTurnJob sends the stored reply to the
# chat by its status (Telegram::Outbound), and while the model works the chat
# shows the typing status (Telegram::Typing, FR-19, NFR-03), the bot's
# "pensando…"; the web page draws its own.
#
# Every model call the turn makes is charged to the month (Budget) as its
# answer arrives, so a run that breaks later, or a worker a deploy stops
# mid-turn, keeps the charge of each call it made: they were paid for (FR-14;
# review finding V3 of pull request #29: a transaction left for the end of the
# run is rolled back when its thread is killed).
class TurnProcessor
  # AgentRunner's, then the four this class adds: a reply the guardrail
  # replaced (FR-20), a turn answered from its stored reservations without
  # the model, one the budget paused and one the job gave up on.
  OUTCOMES = [ *AgentRunner::OUTCOMES.map(&:to_s), "replaced", "reservations", "paused", "dead_letter" ].freeze
  # Which fixed text the system sent in the model's place, by the turn's
  # outcome, for the history of the later turns (Turn::REPLY_KINDS): a
  # replaced reply's is the decline, or the call to call now for an
  # emergency (replaced_emergency), and a command's its own (command).
  # ADR-0003's gate digests it (PromptDigest.history), so every kind the
  # system writes is read from here (the fix review's R3 on pull request #62).
  IN_PLACE = { "refused" => "refusal", "incomplete" => "fallback", "tool_limit" => "fallback", "deadline" => "fallback",
               "model_error" => "fallback", "dead_letter" => "fallback", "paused" => "pause",
               "reservations" => "reservations", "replaced" => "decline", "replaced_emergency" => "call_now",
               "command" => "command" }.freeze

  # A reply holds the system's texts beside the model's own words: the notice
  # before a conversation's first reply, the fixed lines after the words
  # (FixedReply), or a fixed text in their place. Each reply this class
  # stores names, to whoever listens in the process, the words of it the
  # model wrote, which it begins with after any notice (attendant: nil when
  # it holds none), and those of them it wrote before a tool call
  # (before_tools: empty when none). The app has no subscriber; the eval
  # runner's judge reads the system's texts as the system's
  # (lib/evals/pipeline.rb; design §10, M2-3b), since it took the emergency
  # line for the attendant's words, and the evals fail words written before
  # a tool call, which the prompt asks the model never to write (the close
  # of M2-11a2's XC-1).
  REPLY_EVENT = "reply.turn".freeze

  # The attempt of the job that runs the turn (ProcessTurnJob), and the turn
  # that job is for, which the deletion's confirmation counts and names in
  # its lines (FR-05): a later turn's job runs an earlier deletion with its
  # own attempt (the hunter's H3 on pull request #41).
  Attempt = Data.define(:number, :of, :turn_id) do
    def last? = number >= of
    def to_s = "attempt #{number} of #{of} of turn #{turn_id}'s job"
  end

  # The deletion's confirmation did not leave and the turn has another try,
  # so the data waits for it (FR-05).
  class ConfirmationNotSent < StandardError; end

  # A turn runs three times at most, whoever runs it: its own job's attempts,
  # a later turn's job, NFR-03's sweep (StrandedSweepJob). The runs are
  # counted on the turn's row as each starts, so a run that kills its worker
  # counts too, which a count of the usage records would miss: such a run
  # dies before the model's answer is charged (review findings of pull
  # requests #11 and #18).
  RUNS = 3

  # A fourth run: the turn is given up with the fallback, and no model is
  # called (NFR-03).
  class RunsSpent < StandardError; end

  def initialize(turn, commands: CommandPhrases.current, typing: nil, attempt: nil)
    @turn = turn
    @conversation = turn.conversation
    @inbound = turn.inbound_message
    @commands = commands
    @typing = typing
    @attempt = attempt
  end

  # The run is counted before the message is read, so a read that breaks
  # counts too (the verifier's V5 on pull request #48).
  def call
    return if Message.exists?(turn_id: @turn.id)

    @turn.increment!(:runs, touch: true)
    command = @commands.match(@inbound.body)
    return delete if command == :delete
    return give_up(RunsSpent.new("the turn ran #{RUNS} times")) if @turn.runs > RUNS

    TraceRecorder.close_interrupted(@turn)
    @recorder = TraceRecorder.new(@turn)
    case command
    when :reset then reset
    when :trace then trace
    when :start then fixed(:start) { |language| FixedReply.greeting(language) }
    when :help then fixed(:help) { |language| FixedReply.help(language) }
    else answer
    end
  end

  # NFR-03: the job's last attempt failed (ProcessTurnJob's dead letter), or
  # the turn ran three times (RUNS), so the turn is answered with the
  # fallback, followed by the line of any reservation it stored (NFR-02),
  # rather than left waiting for good. It is a run of its own in the trace,
  # with no model call: the root from the message's receipt, the reply, the
  # outcome dead_letter and the error's class.
  #
  # A deletion is never given up (FR-05; review findings C3 and H1 of pull
  # request #41): it keeps no reply, since a fallback after "deleted" would
  # say the opposite of what the visitor read, and a line names it, so the
  # sweep or the visitor's next message runs it again (ProcessTurnJob holds
  # the turns after it meanwhile). Nor is a turn an earlier deletion of its
  # conversation holds, whatever broke its last attempt: it keeps no reply
  # either, and goes with the deletion (the hunter's H5 on pull request #48).
  def give_up(error)
    return if Message.exists?(turn_id: @turn.id)
    return Rails.logger.error("dead letter: turn #{@turn.id} is a deletion that did not go, #{error.class}: no reply, " \
                              "the sweep or the next message runs it again") if deletion?
    return Rails.logger.error("dead letter: turn #{@turn.id} is held by an earlier deletion that did not go, " \
                              "#{error.class}: no reply, the sweep or the next message runs the deletion again") if held?

    TraceRecorder.close_interrupted(@turn)
    @recorder = TraceRecorder.new(@turn)
    @root = @recorder.start_span("balcao.turn", started_at: @inbound.received_at, attributes: {
      "balcao.channel" => @inbound.channel, "balcao.message.source" => @inbound.source
    })
    language = @conversation.language
    stored = reservations
    @exchange = rebuilt(stored)
    finish("dead_letter", "failed", FixedReply.with_reservations(FixedReply.fallback(language), stored, language), error:)
  rescue StandardError => e
    @recorder&.abandon(e.class.name)
    raise
  end

  # FR-05: the turn asks to delete the visitor's data, which ProcessTurnJob
  # lets no later turn pass while it has not gone.
  def deletion? = @commands.match(@inbound.body) == :delete

  private

  # An earlier turn of the conversation asks to delete and has no reply, so
  # its deletion has not gone: one that went took the conversation with it.
  def held?
    Turn.where(conversation_id: @turn.conversation_id).where("(turns.created_at, turns.id) < (?, ?)", @turn.created_at, @turn.id)
        .where.missing(:outbound_message).includes(:inbound_message)
        .any? { |earlier| @commands.match(earlier.inbound_message.body) == :delete }
  end

  # --- Commands -------------------------------------------------------------

  # FR-05: in the same run, the visitor's data goes, and the confirmation
  # goes to the stream, since there is no conversation left to store it in.
  # Nothing is traced: the trace would be deleted with the rest. A trace page
  # open on any of the visitor's conversations is told too, so it drops what
  # it showed (review finding G2 of pull request #17). On Telegram the
  # confirmation goes to the chat first, since the row the deletion takes
  # holds it, and says that the chat in the visitor's app is their own copy
  # (FR-19). The line that the data went without the confirmation is written
  # once it went (the hunter's H2 on pull request #41).
  def delete
    language = command_language
    visitor = @conversation.visitor
    tokens = visitor.conversations.pluck(:trace_token)
    chat = Telegram::Chat.of(visitor)
    unsent = confirm_deletion(chat, language) if chat
    erase(visitor)
    Rails.logger.error("telegram fixed reply deleted: #{unsent}, the data deleted all the same") if unsent
    broadcast(type: "deleted", text: FixedReply.command(:delete, language))
    tokens.each { |token| broadcast({ type: "deleted" }, "trace:#{token}") }
  end

  # The data goes, and in the same transaction the Telegram update that asked
  # for it is stripped, if its read is still open (its strip broke): it is
  # never read again after the deletion, as a person the bot holds no row of,
  # nor given up with the fallback after "deleted" (the hunter's H4 on pull
  # request #48; the owner, 2026-11-19: a delete command never gets the
  # fallback's line, but one never read keeps its "try again").
  def erase(visitor)
    ApplicationRecord.transaction do
      WebhookEvent.strip_unread!(@inbound.webhook_event_id, "processed") if @inbound.webhook_event_id
      visitor.erase!
    end
  end

  # FR-05 on Telegram (the owner, 2026-11-15): the confirmation leaves before
  # the rows go. One that did not leave, or whose send broke (a line names
  # the error's class), raises ConfirmationNotSent, so the job tries the turn
  # again with its backoff, and the turns after it wait for it
  # (ProcessTurnJob#run_earlier, review finding C1 of pull request #41); at
  # the turn's last try, its job's last attempt or its third run, the data
  # goes whether or not the confirmation left, and the log says so once it
  # went (review finding C8 of pull request #33: a send that broke after the
  # deletion was lost with no line). A later turn's job runs the deletion
  # with its own attempt. Past its three runs (the sweep, a later message), a
  # deletion that still did not go sends its confirmation no more, so a
  # deletion that keeps breaking does not write "deleted" to the chat at
  # every run. A confirmation may arrive twice when a run is repeated:
  # sendMessage takes no idempotency key (NFR-02's accepted duplicate). It
  # takes the reply keyboard away, as any fixed line to a person who agreed:
  # FR-21's openers would outlive the data (FR-19; review finding C3 of pull
  # request #47).
  #
  # Answers nil once it left, else what the line after the deletion says.
  def confirm_deletion(chat, language)
    return "not sent again after the turn's #{RUNS} runs" if @turn.runs > RUNS

    left = begin
      Telegram::Outbound.new.send_fixed(chat, FixedReply.telegram_deleted(language), keyboard: Telegram::Outbound::REMOVE_KEYBOARD,
                                                                                   name: :deleted, attempt: @attempt)
    rescue StandardError => e
      Rails.logger.error("telegram fixed reply deleted: broke#{" at #{@attempt}" if @attempt}, #{e.class}")
      false
    end
    return if left
    raise ConfirmationNotSent, "the deletion's confirmation did not leave; the job tries the turn again" unless last_try?

    "not sent"
  end

  def last_try? = @attempt&.last? || @turn.runs >= RUNS

  # FR-04: the conversation closes and the reply opens the next one, so its
  # confirmation carries the notice.
  #
  # The intake puts a message in the open conversation when it arrives, so a
  # message sent while this reset waited its turn sits in the conversation
  # the reset closes. It was sent after the reset: it moves, with its turn, to
  # the conversation the reset opens, and its model never reads what came
  # before (review findings V1 and R2 of pull request #11); a second reset
  # among those messages starts over again in its turn. One transaction
  # closes, opens, moves and confirms, and marks the turn replied (command),
  # so a moved turn's job, which runs it under the new conversation's lock
  # (ProcessTurnJob), finds the confirmation already there and gives no
  # second notice.
  def reset
    language = command_language
    command(:reset) do
      @conversation.update!(closed_at: Time.current) if @conversation.closed_at.nil?
      current = Conversation.current_for!(@conversation.visitor)
      current.update!(language:) unless current.messages.outbound.exists?
      move_later_turns(current)
      record_reply(FixedReply.command(:reset, language), conversation: current, language:)
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

  # FR-12: the link to this conversation's trace page (Conversation#trace_url).
  def trace
    language = command_language
    command(:trace) { record_reply(FixedReply.command(:trace, language, url: @conversation.trace_url), conversation: @conversation, language:) }
  end

  # FR-19, FR-18: /start's greeting and /help's list, fixed texts on every
  # channel; the first reply of a conversation carries the notice before them.
  def fixed(name)
    language = command_language
    command(name) { record_reply(yield(language), conversation: @conversation, language:) }
  end

  # The block stores the command's reply, which the turn's state joins in one
  # transaction (replied). A command that breaks is marked failed with its
  # span closed by the error, as a turn that breaks outside the model is, for
  # the job's retry (review finding C4 of pull request #11).
  def command(name)
    @inbound.update_columns(source: "command")
    span = @recorder.start_span("balcao.command", started_at: @inbound.received_at,
                                                  attributes: { "balcao.command.name" => name.to_s })
    broadcast_reply(replied("replied", span, kind: IN_PLACE.fetch("command")) { yield })
  rescue StandardError => e
    broken(e)
    raise
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
    @root = @recorder.start_span("balcao.turn", started_at: @inbound.received_at, attributes: {
      "balcao.channel" => @inbound.channel, "balcao.message.source" => @inbound.source
    })
    stored = reservations
    if stored.any?
      @exchange = rebuilt(stored)
      return finish("reservations", "replied", FixedReply.reservations(stored, @conversation.language))
    end

    budget = Budget.status
    return paused(budget) if budget.mode == "paused"

    run_model(canary? ? "economy" : budget.mode)
  rescue StandardError => e
    broken(e)
    raise
  end

  # FR-17, ADR-0003: the canary's question runs on the economy model in
  # every mode that calls one, whatever ADR-0003's gate says, since its reply
  # reaches no visitor; a pause answers it with the pause's text, as any.
  def canary? = @inbound.source_canary?

  # FR-14: the demo is paused, so the reply is the pause's, with no model:
  # the forced pause's own (the owner, 2026-11-15), the day's until midnight
  # when the day's slice paused it, or the month's (the cap, or the month's
  # economy the gate keeps closed); a model an earlier run of the turn named
  # is no longer the turn's.
  def paused(budget)
    @turn.update!(mode: "paused", model: nil)
    @root.attributes["balcao.turn.mode"] = "paused"
    language = @conversation.language
    text = if budget.forced then FixedReply.forced_pause(language)
    elsif budget.daily then FixedReply.daily_pause(language)
    else FixedReply.paused(language)
    end
    finish("paused", "replied", text)
  end

  def run_model(mode)
    @turn.update!(mode:, model: ModelPolicy.route(mode).model)
    @root.attributes["balcao.turn.mode"] = mode
    events = TurnTrace.new(@recorder, @root)
    edge = TurnEdge.after(canary? ? Canary::WITHIN.to_i : AgentRunner::WALL_CLOCK)
    result, verdict = typing.during do
      result = AgentRunner.new.run(@turn, mode:, edge:) do |event|
        Budget.charge!(@turn, event.usage) if event.is_a?(AgentRunner::ModelCall)
        events.on(event)
      end
      [ result, guard(result, events, edge) ]
    end
    @exchange = result.exchange.presence
    @conversation.update!(language: result.language) if result.language
    return replace(result) if verdict&.clinical?

    # A reply the edge left unchecked is not sent: the turn's sixty seconds
    # are spent, and SR-20 answers that with the fallback (M3-4).
    result = result.with(outcome: :deadline, text: nil) if verdict&.error == Guardrail::DEADLINE

    text, state = reply_of(result)
    wrote = result.outcome == :replied
    finish(result.outcome, state, text, error: result.error, own: (result.text if wrote), written: (result.written if wrote),
                                        before_tools: (result.before_tools if wrote))
  end

  # FR-20: the text the model wrote passes the guardrail's check before it is
  # sent, while the chat still shows the typing status; a reply that is its
  # tags alone is the system's own line, and the fixed replies never come
  # here. The check's span is the trace's and its usage is charged as it
  # arrives, as a model call's are. A check that gave no verdict is a line,
  # and the reply goes as the model wrote it (threat model R4). The verdict
  # is traced, and a check without one logged, before the charge: a charge
  # that breaks breaks the turn, for the job's retry, and the trace still
  # says what the check found (review finding V1 of pull request #54, the
  # hunter's H7).
  def guard(result, events, edge)
    return unless result.outcome == :replied && result.text.present?

    Guardrail.new.check(message: @inbound.body, reply: result.text, earlier: earlier_messages, edge:) do |event|
      events.on(event)
      next unless event.is_a?(Guardrail::Verdict)

      log_no_verdict(event) if event.error
      Budget.charge!(@turn, event.usage)
    end
  end

  def log_no_verdict(verdict)
    if verdict.error == Guardrail::DEADLINE
      Rails.logger.error("turn #{@turn.id}: the turn's edge cut the guardrail's check; the fallback is sent in the reply's place")
    else
      Rails.logger.error("turn #{@turn.id}: the guardrail gave no verdict (#{verdict.error}); the reply is sent as the model wrote it")
    end
  end

  # The visitor's messages before this turn's, oldest first, in the window
  # the model read (AgentRunner::History): a short reply may answer a
  # question asked turns before (review finding C2 of pull request #54).
  def earlier_messages
    Turn.where(conversation_id: @turn.conversation_id).where("(turns.created_at, turns.id) < (?, ?)", @turn.created_at, @turn.id)
        .order(created_at: :desc, id: :desc).limit(AgentRunner::History::TURNS - 1)
        .includes(:inbound_message).to_a.reverse.map { |earlier| earlier.inbound_message.body }
  end

  def reply_of(result)
    language = @conversation.language
    case result.outcome
    when :replied then [ with_facts(result, language), "replied" ]
    when :refused then [ FixedReply.with_reservations(FixedReply.with_emergency(FixedReply.declined(language), language),
                                                      reservations, language), "replied" ]
    else [ FixedReply.with_reservations(fallback(result, language), reservations, language), "failed" ]
    end
  end

  # NFR-03's fallback, followed by the emergency line when the reply the
  # turn's edge left unchecked asked for it: the line is the system's own
  # text, and an emergency's one instruction (FR-09, SR-20).
  def fallback(result, language)
    text = FixedReply.fallback(language)
    result.emergency ? FixedReply.with_emergency(text, language) : text
  end

  # FR-20: a reply the check found clinical is FR-09's decline, followed by
  # the offer of the pharmacist, as any reply's lines are; then the facts the
  # turn's tools produced, as fixed lines: the products it found that the
  # visitor's message names, with their prices, and the reservations it
  # stored or that the cap of open ones listed (FR-07). A reply that asked
  # for the emergency line opens with the call to call now instead, then the
  # line, and lists no product (FR-09: an emergency's one instruction is to
  # call for help; #59's M1, the owner, 2026-11-20). Nothing of the model's
  # text is kept. A replacement that breaks breaks the turn, for the job's
  # retry: the fail-open of threat model R4 is the check's alone, and the
  # clinical text is never sent.
  def replaced(result, language)
    products = result.emergency ? [] : products_of(result)
    reply = if result.emergency then FixedReply.with_emergency(FixedReply.call_now(language), language)
    else FixedReply.with_products(with_lines(FixedReply.declined(language), language, offer: true), products, language)
    end
    [ FixedReply.with_reservations(reply, facts_of(result), language), products.size ]
  end

  # The replacement stored, one line says so, with the turn's id and what it
  # listed, never a word of the reply or of the visitor (threat model SR-30):
  # the trace of the conversation was the only place that showed it, so a
  # check that began to replace right answers across the demo went unseen
  # (review finding H-B4 of pull request #60).
  def replace(result)
    text, listed = replaced(result, @conversation.language)
    finish("replaced", "replied", text, kind: IN_PLACE.fetch(result.emergency ? "replaced_emergency" : "replaced"))
    Rails.logger.warn("turn #{@turn.id}: FR-20's check replaced the model's reply (products listed: #{listed}, emergency: #{result.emergency})")
  end

  # The products the searches found that the visitor's message names, each
  # once, at most one search's worth, as the catalogue lists them now: this
  # turn's searches first, then the earlier turns' in the window the model
  # read, newest first, from their stored tool exchanges, since the model may
  # answer a follow-up from its own earlier reply, which named the product,
  # without searching again (review finding H-B5 of pull request #60); the
  # history no longer gives the model a search back (AgentRunner::History,
  # REPLAYED; the close's TR-3). A product the model chose for what the message describes,
  # a symptom among them, is not one it names, so a replacement never lists
  # it as the system's own line (#59's C2 and H2, the owner, 2026-11-20;
  # Product.named_in).
  def products_of(result)
    found = result.tool_calls.select { |call| call.name == "search_products" && !call.is_error }
                  .flat_map { |call| JSON.parse(call.output).fetch("products").map { |product| product.fetch("id") } }
    ids = (found + earlier_found).uniq
    named = Product.named_in(@inbound.body, ids).index_by(&:id)
    ids.filter_map { |id| named[id] }.first(Tools::SearchProducts::MAX_RESULTS).map { |product| Tools::SearchProducts.listing(product) }
  end

  # The ids of the products the earlier turns' searches found, from their
  # tool exchanges (Turn#tool_exchange), newest turn first, in the window
  # the model read (AgentRunner::History).
  def earlier_found
    Turn.where(conversation_id: @turn.conversation_id).where("(turns.created_at, turns.id) < (?, ?)", @turn.created_at, @turn.id)
        .order(created_at: :desc, id: :desc).limit(AgentRunner::History::TURNS - 1)
        .filter_map(&:tool_exchange).flat_map { |exchange| searched(exchange) }
  end

  def searched(exchange)
    blocks = exchange.flat_map { |message| message["content"] }
    searches = blocks.filter_map { |block| block["id"] if block["type"] == "tool_use" && block["name"] == "search_products" }
    blocks.select { |block| block["type"] == "tool_result" && searches.include?(block["tool_use_id"]) && !block["is_error"] }
          .flat_map { |block| JSON.parse(block["content"]).fetch("products").map { |product| product.fetch("id") } }
  end

  def reservations = Reservation.where(turn_id: @turn.id).includes(:product).order(:created_at, :id).to_a

  # The tool exchange of a reply the system sent without running the model,
  # a run's again that found the turn's reservations stored or the dead
  # letter's fallback: the calls that made the turn's reservations and their
  # results, rebuilt from the stored rows, in the shape AgentRunner::Run
  # keeps (Turn#tool_exchange), or nil for a turn that reserved nothing.
  # Each reservation of a turn was made by the model's own call in an
  # earlier run of it, whose exchange was lost when that run broke before
  # its reply was stored; without it, the next turn's history named no code
  # for the reservations the visitor read, and the model has no tool to look
  # them up (the close's XF-C2, the owner, 2026-11-20). A call's id is the
  # reservation's, so the history reads the same on every turn and its
  # cached prefix holds.
  def rebuilt(stored)
    return if stored.empty?

    ids = stored.to_h { |reservation| [ reservation, "toolu_#{reservation.id.delete("-")}" ] }
    calls = stored.map do |reservation|
      { "type" => "tool_use", "id" => ids[reservation], "name" => Tools::CreateReservation.api_name,
        "input" => { "product_id" => reservation.product_id, "quantity" => reservation.quantity } }
    end
    results = stored.map do |reservation|
      { "type" => "tool_result", "tool_use_id" => ids[reservation], "content" => JSON.generate(Tools::CreateReservation.result(reservation)),
        "is_error" => false }
    end
    [ { "role" => "assistant", "content" => calls }, { "role" => "user", "content" => results } ]
  end

  # The turn's reservations and, when the cap of open reservations refused
  # one, those the visitor holds (FR-07).
  def facts_of(result)
    facts = reservations
    facts |= held_reservations if result.tool_calls.any? { |call| call.refusal == "open_limit" }
    facts
  end

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
    reply = with_lines(text, language, offer: result.offer, emergency: result.emergency)
    FixedReply.with_reservations(reply, facts_of(result).reject { |reservation| written?(text, reservation) }, language)
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

  # own is the model's words the text begins with, nil when it holds none,
  # and before_tools those of them written before a tool call (REPLY_EVENT);
  # written, the reply as the model wrote it, and kind, what the later
  # turns' history gives back of the turn (Turn::REPLY_KINDS): model for a
  # reply the model wrote, else the fixed text sent in its place.
  def finish(outcome, state, text, error: nil, own: nil, written: nil, kind: nil, before_tools: nil)
    raise ArgumentError, "#{outcome} is not in TurnProcessor::OUTCOMES" unless OUTCOMES.include?(outcome.to_s)

    kind ||= outcome.to_s == "replied" ? "model" : IN_PLACE.fetch(outcome.to_s)
    outbound = @recorder.start_span("balcao.outbound", parent: @root, attributes: { "balcao.message.author" => "bot" })
    message = replied(state, @root, kind:, written:) do
      record_reply(text, conversation: @conversation, language: @conversation.language, own:, before_tools:)
    end
    broadcast_reply(message)
    outbound.finish(attributes: { "balcao.message.characters" => message.body.length })
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
  # closed with the error and it is marked failed, for the job's retry. One
  # whose reply is stored keeps the state its reply's transaction wrote
  # (review finding C6 and the hunter's H8 of pull request #48).
  def broken(error)
    @recorder.abandon(error.class.name)
    @turn.update_columns(state: "failed") unless Message.exists?(turn_id: @turn.id)
  rescue StandardError => e
    Rails.logger.error("turn #{@turn.id} not marked failed: #{e.class}")
  end

  # --- The reply --------------------------------------------------------------

  # The reply the block stores, the turn's state and, on Telegram, the span
  # of the reply's way to the chat (delivery), under the parent given, in one
  # transaction: a run that breaks between them leaves none (review finding
  # V2 of pull request #11), the turn failed with no reply, for the job's
  # retry; and the span is there before anything else can see the reply, so
  # a drain of the person's replies that sends it at once finds the span to
  # close (review finding V4 of pull request #48). The caller sends the reply
  # to the stream once it is committed. The turn keeps, with its reply, what
  # the history of the later turns gives back of it (AgentRunner::History):
  # the reply as the model wrote it, or which fixed text the system sent in
  # its place (kind), and the tool calls the model made in this run with
  # their results.
  def replied(state, parent, kind:, written: nil)
    ApplicationRecord.transaction do
      yield.tap do
        @turn.update!(state:, reply_kind: kind, model_reply: written, **latency, **exchange)
        delivery(parent)
      end
    end
  end

  def exchange = @exchange ? { tool_exchange: @exchange } : {}

  # FR-12, FR-19: a Telegram reply leaves after its run, by its status
  # (Telegram::Outbound), so the run opens its delivery's span and leaves it
  # open, and Outbound closes it when Telegram takes the reply, or with the
  # error that failed it (TraceRecorder.delivered): the trace says whether the
  # reply left, and when (#45's verifier, V4). A web reply is sent as it is
  # stored, to the page's stream.
  def delivery(parent) = (@recorder.start_delivery(parent) if @inbound.channel == "telegram")

  def record_reply(text, conversation:, language:, own: nil, before_tools: nil)
    body = conversation.messages.outbound.exists? ? text : FixedReply.with_notice(text, language)
    Message.record_outbound!(turn: @turn, body:, conversation:).tap do
      ActiveSupport::Notifications.instrument(REPLY_EVENT, turn_id: @turn.id, attendant: own.presence, before_tools: Array(before_tools))
    end
  end

  # The stored reply to the conversation's stream, after the commit. The
  # codes and the payload are read here, so a read that breaks is a line, as
  # a broadcast that fails is, and never breaks a turn whose reply is stored
  # (review finding C6 and the hunter's H8 of pull request #48).
  def broadcast_reply(message)
    return unless @conversation.streamed?

    codes = Reservation.where(visitor_id: @conversation.visitor_id).pluck(:code)
    broadcast(type: "message", message: message.stream_payload(reservation_codes: codes))
  rescue StandardError => e
    Rails.logger.error("turn #{@turn.id}: message not broadcast: #{e.class}")
  end

  # On the stream of the turn's conversation, the one the visitor's page
  # follows; a reset's reply names the conversation it opened. A broadcast
  # that fails leaves the reply stored for the page to poll (FR-18). The
  # system visitor's conversation has no stream (FR-17's null transport).
  def broadcast(payload, stream = "conversation:#{@conversation.id}")
    return unless @conversation.streamed?

    ActionCable.server.broadcast(stream, payload)
  rescue StandardError => e
    Rails.logger.error("turn #{@turn.id}: #{payload[:type]} not broadcast: #{e.class}")
  end

  # NFR-01's figure, from the message's receipt to the reply's send: a web
  # reply is sent here, as it is stored, to the page's stream; a Telegram
  # reply leaves after the turn, by its status, and Telegram::Outbound writes
  # the figure when the Bot API takes it (Turn#reply_sent!).
  def latency = @inbound.channel == "telegram" ? {} : { latency_ms: @turn.latency_until(Time.current) }

  # The channel's sign that a reply is on its way while the model works
  # (design §6.3): Telegram's typing status, nothing on the web.
  def typing = @typing ||= Telegram::Typing.for(@conversation.visitor)
end
