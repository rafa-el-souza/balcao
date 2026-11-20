require_relative "case_set"

# Runs a case once through the app's own turn pipeline (evals/README.md: the
# cases run through the full pipeline against a seeded database, not through
# the agent runner alone). A new web visitor sends the case's messages one by
# one; Intake stores each as the web channel does, and ProcessTurnJob, run
# inline, answers it before the next is sent, so each earlier reply is the
# attendant's own, live. What the visitor got is then read back from what the
# app stored and sent: the reply (a deletion's confirmation from the stream,
# since no conversation is left to store it in), each turn's spans (FR-12),
# FR-20's check of the reply with the reason the check gave (Guardrail::EVENT,
# since the trace never keeps it), and the visitor's rows. The reply is also
# read in its authors' parts, which the judge reads: the words the model
# wrote, as its turn names them (TurnProcessor::REPLY_EVENT), and the
# system's texts around them or in their place (design §10, M2-3b).
#
# The attempt runs in the test environment (bin/evals), inside one
# transaction rolled back at its end: it starts with no visitor, the
# catalogue of the case's seed and a month forced to the run's mode, and no
# attempt sees another's reservations, stock or conversations. Nothing the app
# does in a turn waits for a commit.
#
# The mode is the route's (ModelPolicy): normal, or economy for FR-09 on the
# economy model, which serves only on ADR-0003's gate. The run is what writes
# the gate (EconomyGate), so on the economy route the gate is open for the
# attempt alone, whatever the boot read, and closed again after it.
# The transaction is not joinable, so each of the app's own transaction
# blocks is a savepoint of it and rolls back with its block, as it does in
# production, when an exception leaves the block (the eval audit's finding
# 5, pull request #20's line C7S3).
module Evals
  class Pipeline
    # One message of the case and what it got. reply is what the visitor
    # read, notice included; outcome is the turn's root span's, "command" for
    # a command's turn, "deleted" for a deletion, or "none" when no reply came.
    # guardrail is FR-20's check of the reply, nil for a turn it did not read.
    # mode is the budget's mode the turn ran in, nil for a turn that read
    # none (a command). attendant is the words of the reply the model wrote,
    # which it begins with after the notice, nil when it holds none (a
    # command's reply, a decline or a fallback in the model's place).
    TurnRecord = Data.define(:message, :reply, :notice, :outcome, :error_type, :latency_ms, :model_calls, :tool_calls, :guardrail, :mode,
                             :attendant) do
      def initialize(guardrail: nil, mode: nil, attendant: nil, **) = super
    end
    # FR-20's check of a turn's reply, as its span recorded it (TurnTrace),
    # with the reason the check gave, which only the run hears
    # (Guardrail::EVENT): clinical is nil, and error_type set, for a check
    # that gave no verdict.
    GuardrailCheck = Data.define(:clinical, :reason, :model, :error_type, :input_tokens, :output_tokens, :latency_ms)
    # A model call as its span recorded it: the input counts the cache read
    # and written (TurnTrace); iterations lists the attempts of a call the
    # refusal fallback served (ADR-0003).
    ModelCall = Data.define(:model, :stop_reason, :input_tokens, :output_tokens, :cache_read_tokens, :cache_write_tokens,
                            :iterations, :latency_ms, :error_type)
    Run = Data.define(:turns, :observation)

    # A stored reply whose authors the run cannot tell: its turn named no
    # words of it, or words it does not begin with. The judge never reads
    # such a reply as anyone's; the attempt is the harness's error.
    class Unattributed < StandardError; end

    attr_reader :mode

    def initialize(mode: "normal")
      @mode = ModelPolicy.route(mode).mode
    end

    def run(kase)
      result = nil
      gate do
        ApplicationRecord.transaction(requires_new: true, joinable: false) do
          prepare(kase.seed)
          identity_hash = SecureRandom.hex(32)
          said = kase.messages.map { |text| say(identity_hash, text) }
          result = Run.new(turns: said.map(&:first), observation: observe(identity_hash, *said.last, earlier: said[...-1].map { |record, _| record.reply }))
          raise ActiveRecord::Rollback
        end
      end
      result
    end

    private

    def gate(&)
      return yield unless @mode == "economy"

      allowed = Rails.configuration.x.economy_allowed
      begin
        Rails.configuration.x.economy_allowed = true
        yield
      ensure
        Rails.configuration.x.economy_allowed = allowed
      end
    end

    # No visitor, so no conversation or reservation, the case's catalogue
    # (evals/seeds overlays the default one, README, Seeds), and the month
    # forced to the run's mode, whatever its row said or spent.
    def prepare(seed)
      Visitor.delete_all
      overlay = CaseSet::SEEDS.join("#{seed}.yml") unless seed == "default"
      CatalogueSeed.seed!(CatalogueSeed.entries(overlay:))
      BudgetState.for_month!.update!(forced_mode: @mode)
    end

    # As the web channel takes a message (Api::MessagesController): the
    # visitor identified by its token on every message, so one who deleted
    # their data starts over (FR-05), and the text without a NUL or the
    # spaces around it (review finding C2 of pull request #20).
    def say(identity_hash, text)
      visitor = Visitor.identify!(channel: "web", identity_hash:)
      turn = Intake.new(visitor).receive!(external_id: SecureRandom.uuid, body: text.delete("\u0000").strip)
      stream = "conversation:#{turn.conversation_id}"
      sent = []
      verdicts = []
      named = []
      collect = ->(*args) { sent << args.last[:message] if args.last[:broadcasting] == stream }
      checked = ->(*args) { verdicts << args.last[:verdict] }
      authored = ->(*args) { named << args.last }
      ActiveSupport::Notifications.subscribed(authored, TurnProcessor::REPLY_EVENT) do
        ActiveSupport::Notifications.subscribed(checked, Guardrail::EVENT) do
          ActiveSupport::Notifications.subscribed(collect, "broadcast.action_cable") { ProcessTurnJob.perform_now(turn.id) }
        end
      end
      clear_enqueued_jobs
      [ record(turn, text, sent, verdicts.last, named), turn.conversation_id, visitor ]
    end

    def record(turn, text, sent, verdict = nil, named = [])
      reply = Message.find_by(turn_id: turn.id)&.trace_payload
      deleted = sent.reverse.find { |payload| payload[:type] == "deleted" }
      # In the order they were written (the ids are uuidv7): a model call's
      # span when it starts, a tool call's when it returns, dated back by its
      # latency, so its start time does not order it.
      spans = TraceEvent.where(turn_id: turn.id).order(:id).to_a
      root = spans.find { |span| span.name == "balcao.turn" }
      TurnRecord.new(
        message: text, reply: reply ? [ reply[:notice], reply[:body] ].compact.join("\n\n") : deleted&.dig(:text),
        notice: reply&.dig(:notice), outcome: outcome(root, spans, reply || deleted, deleted),
        error_type: root&.span_attributes&.dig("error.type"), latency_ms: Turn.find_by(id: turn.id)&.latency_ms,
        model_calls: spans.select { |span| span.name == TurnTrace::MODEL_CALL }.map { |span| model_call(span.span_attributes) },
        tool_calls: spans.select { |span| span.name.start_with?("#{TurnTrace::TOOL_CALL} ") }.map { |span| tool_call(span.span_attributes) },
        guardrail: guardrail(spans.reverse.find { |span| span.name == TurnTrace::GUARDRAIL }, verdict),
        mode: root&.span_attributes&.dig("balcao.turn.mode"), attendant: attendant_of(turn, reply, named)
      )
    end

    # The model's words of the turn's stored reply, as the turn named them
    # (TurnProcessor::REPLY_EVENT), its last naming if a run was repeated; nil
    # for a reply the system wrote in the model's place, or for no reply.
    def attendant_of(turn, reply, named)
      return unless reply

      naming = named.reverse.find { |event| event[:turn_id] == turn.id }
      raise Unattributed, "turn #{turn.id}'s stored reply named no words as the model's or the system's" unless naming

      words = naming[:attendant]
      raise Unattributed, "turn #{turn.id}'s stored reply does not begin with the words its turn named" if words && !reply[:body].start_with?(words)

      words
    end

    # The reply in its authors' parts, in the order the visitor read them:
    # the notice, the model's words, and the system's lines after them; a
    # reply with no words of the model's (a decline or a fallback in their
    # place, a command's, a deletion's) is the system's whole.
    def parts_of(record)
      return [] unless record.reply

      body = record.notice ? record.reply.delete_prefix(record.notice).delete_prefix("\n\n") : record.reply
      rest = record.attendant ? body.delete_prefix(record.attendant).delete_prefix("\n\n") : body
      [ (Part.new(author: :system, text: record.notice) if record.notice), (Part.new(author: :attendant, text: record.attendant) if record.attendant),
        (Part.new(author: :system, text: rest) if rest.present?) ].compact
    end

    # The last check of the turn's spans, the reason from the check itself.
    def guardrail(span, verdict)
      return unless span

      attributes = span.span_attributes
      GuardrailCheck.new(clinical: attributes["balcao.guardrail.clinical"], reason: verdict&.reason,
                         model: attributes["gen_ai.response.model"] || attributes["gen_ai.request.model"],
                         error_type: attributes["error.type"], input_tokens: attributes["gen_ai.usage.input_tokens"].to_i,
                         output_tokens: attributes["gen_ai.usage.output_tokens"].to_i, latency_ms: attributes["balcao.latency_ms"])
    end

    def outcome(root, spans, replied, deleted)
      return root.span_attributes["balcao.turn.outcome"] || "none" if root
      return "deleted" if deleted
      return "command" if replied && spans.any? { |span| span.name == "balcao.command" }

      "none"
    end

    def model_call(attributes)
      ModelCall.new(model: attributes["gen_ai.response.model"] || attributes["gen_ai.request.model"],
                    stop_reason: attributes["anthropic.message.stop_reason"],
                    input_tokens: attributes["gen_ai.usage.input_tokens"].to_i, output_tokens: attributes["gen_ai.usage.output_tokens"].to_i,
                    cache_read_tokens: attributes["gen_ai.usage.cache_read.input_tokens"].to_i,
                    cache_write_tokens: attributes["gen_ai.usage.cache_write.input_tokens"].to_i,
                    iterations: attributes["anthropic.usage.iterations"], latency_ms: attributes["balcao.latency_ms"],
                    error_type: attributes["error.type"])
    end

    # The arguments are JSON the trace cut at 500 characters; a cut one is
    # not read.
    def tool_call(attributes)
      input = begin
        JSON.parse(attributes["gen_ai.tool.call.arguments"].to_s)
      rescue JSON::ParserError
        nil
      end
      ToolCall.new(name: attributes["gen_ai.tool.name"], input: (input if input.is_a?(Hash)),
                   output: attributes["anthropic.tool_result.content"], refusal: attributes["balcao.tool_result.refusal"],
                   failed: attributes["error.type"] == "tool_error")
    end

    # The last message's reply, the turn's tool calls, and the rows of the
    # visitor who sent it: a reservation (FR-07), the case's conversation
    # closed with another open (FR-04), nothing left under the visitor's
    # identity (FR-05); and the replies to the earlier messages.
    def observe(identity_hash, last, conversation_id, visitor, earlier:)
      Observation.new(
        reply: last.reply, notice: last.notice, parts: parts_of(last), tool_calls: last.tool_calls, earlier:,
        guardrail_replaced: last.outcome == "replaced", guardrail_reason: last.guardrail&.reason,
        reservation_created: Reservation.exists?(visitor_id: visitor.id),
        conversation_reset: Conversation.where(id: conversation_id).where.not(closed_at: nil).exists? &&
          Conversation.where(visitor_id: visitor.id, closed_at: nil).where.not(id: conversation_id).exists?,
        data_deleted: !Visitor.exists?(channel: "web", identity_hash:) && !Conversation.exists?(visitor_id: visitor.id) &&
          !Reservation.exists?(visitor_id: visitor.id)
      )
    end

    # The jobs Intake enqueued are run inline here; the test adapter keeps
    # them otherwise.
    def clear_enqueued_jobs
      adapter = ActiveJob::Base.queue_adapter
      adapter.enqueued_jobs.clear if adapter.respond_to?(:enqueued_jobs)
    end
  end
end
