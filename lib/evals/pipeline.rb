require_relative "case_set"

# Runs a case once through the app's own turn pipeline (evals/README.md: the
# cases run through the full pipeline against a seeded database, not through
# the agent runner alone). A new web visitor sends the case's messages one by
# one; Intake stores each as the web channel does, and ProcessTurnJob, run
# inline, answers it before the next is sent, so each earlier reply is the
# attendant's own, live. What the visitor got is then read back from what the
# app stored and sent: the reply (a deletion's confirmation from the stream,
# since no conversation is left to store it in), each turn's spans (FR-12),
# and the visitor's rows.
#
# The attempt runs in the test environment (bin/evals), inside one
# transaction rolled back at its end: it starts with no visitor and the
# catalogue of the case's seed, and no attempt sees another's reservations,
# stock or conversations. Nothing the app does in a turn waits for a commit.
module Evals
  class Pipeline
    # One message of the case and what it got. reply is what the visitor
    # read, notice included; outcome is the turn's root span's, "command" for
    # a command's turn, "deleted" for a deletion, or "none" when no reply came.
    TurnRecord = Data.define(:message, :reply, :notice, :outcome, :error_type, :latency_ms, :model_calls, :tool_calls)
    # A model call as its span recorded it: the input counts the cache read
    # and written (TurnTrace); iterations lists the attempts of a call the
    # refusal fallback served (ADR-0003).
    ModelCall = Data.define(:model, :stop_reason, :input_tokens, :output_tokens, :cache_read_tokens, :cache_write_tokens,
                            :iterations, :latency_ms, :error_type)
    Run = Data.define(:turns, :observation)

    def run(kase)
      result = nil
      ApplicationRecord.transaction(requires_new: true) do
        prepare(kase.seed)
        identity_hash = SecureRandom.hex(32)
        said = kase.messages.map { |text| say(identity_hash, text) }
        result = Run.new(turns: said.map(&:first), observation: observe(identity_hash, *said.last))
        raise ActiveRecord::Rollback
      end
      result
    end

    private

    # No visitor, so no conversation or reservation, and the case's catalogue
    # (evals/seeds overlays the default one, README, Seeds).
    def prepare(seed)
      Visitor.delete_all
      overlay = CaseSet::SEEDS.join("#{seed}.yml") unless seed == "default"
      CatalogueSeed.seed!(CatalogueSeed.entries(overlay:))
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
      collect = ->(*args) { sent << args.last[:message] if args.last[:broadcasting] == stream }
      ActiveSupport::Notifications.subscribed(collect, "broadcast.action_cable") { ProcessTurnJob.perform_now(turn.id) }
      clear_enqueued_jobs
      [ record(turn, text, sent), turn.conversation_id, visitor ]
    end

    def record(turn, text, sent)
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
        tool_calls: spans.select { |span| span.name.start_with?("#{TurnTrace::TOOL_CALL} ") }.map { |span| tool_call(span.span_attributes) }
      )
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
    # identity (FR-05).
    def observe(identity_hash, last, conversation_id, visitor)
      Observation.new(
        reply: last.reply, notice: last.notice, tool_calls: last.tool_calls,
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
