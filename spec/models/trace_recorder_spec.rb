require "rails_helper"

RSpec.describe "ADR-0010 TraceRecorder, the trace of a turn in the shape of OpenTelemetry (FR-12, SR-12)" do
  let(:turn) { create(:turn) }
  let(:conversation) { turn.conversation }
  let(:recorder) { TraceRecorder.new(turn) }
  let(:streams) { [ "conversation:#{conversation.id}", "trace:#{conversation.trace_token}" ] }

  describe "spans" do
    it "stores one row per span with a 128-bit trace id and a 64-bit span id in lowercase hex" do
      root = recorder.start_span("balcao.turn", attributes: { "balcao.channel" => "web" })
      child = recorder.start_span("anthropic.messages.create", parent: root)

      rows = TraceEvent.where(turn:).order(:started_at, :created_at)
      expect(rows.map(&:name)).to eq([ "balcao.turn", "anthropic.messages.create" ])
      expect(rows.map(&:trace_id).uniq).to eq([ recorder.trace_id ])
      expect(recorder.trace_id).to match(/\A[0-9a-f]{32}\z/)
      expect(rows.map(&:span_id)).to all(match(/\A[0-9a-f]{16}\z/))
      expect(rows.last.parent_span_id).to eq(root.span_id)
      expect(rows.first.parent_span_id).to be_nil
      expect(child.span_id).not_to eq(root.span_id)
    end

    it "gives every run of a turn its own trace id" do
      expect(TraceRecorder.new(turn).trace_id).not_to eq(TraceRecorder.new(turn).trace_id)
    end

    it "closes the row on finish, merging the finishing attributes" do
      travel_to(Time.zone.local(2026, 11, 11, 15, 0, 0)) do
        span = recorder.start_span("anthropic.messages.create", attributes: { "gen_ai.request.model" => "claude-opus-5-5" })
        travel 2.seconds
        span.finish(attributes: { "gen_ai.usage.output_tokens" => 80 })
      end

      row = TraceEvent.sole
      expect(row.finished_at - row.started_at).to eq(2)
      expect(row.span_attributes).to eq("gen_ai.request.model" => "claude-opus-5-5", "gen_ai.usage.output_tokens" => 80)
    end

    it "starts a span at the time it is given, so the turn's span starts at the message's receipt (NFR-01)" do
      received = 3.seconds.ago.change(usec: 0)
      recorder.start_span("balcao.turn", started_at: received)

      expect(TraceEvent.sole.started_at).to eq(received)
    end

    it "finishes a span once" do
      span = recorder.start_span("balcao.outbound")
      span.finish
      first = TraceEvent.sole.finished_at

      travel(1.second) { span.finish(attributes: { "error.type" => "late" }) }

      expect(TraceEvent.sole).to have_attributes(finished_at: first, span_attributes: {})
    end
  end

  describe "broadcasts (FR-12)" do
    it "sends each span twice, on start and on finish, to the conversation's stream and its trace page's" do
      started = a_hash_including(type: "span", span: a_hash_including(name: "anthropic.messages.create", finished_at: nil))
      finished = a_hash_including(type: "span", span: a_hash_including(attributes: { "gen_ai.usage.output_tokens" => 80 },
                                                                         finished_at: a_string_matching(/\A\d{4}-/)))
      span = nil

      expect { span = recorder.start_span("anthropic.messages.create") }
        .to have_broadcasted_to(streams.first).with(started).and have_broadcasted_to(streams.last).with(started)
      expect { span.finish(attributes: { "gen_ai.usage.output_tokens" => 80 }) }
        .to have_broadcasted_to(streams.first).with(finished).and have_broadcasted_to(streams.last).with(finished)
    end
  end

  describe "what a span may carry (SR-12)" do
    it "refuses an attribute outside its allow-list" do
      expect { recorder.start_span("balcao.turn", attributes: { "balcao.visitor.identity_hash" => "abc" }) }
        .to raise_error(ArgumentError, /balcao\.visitor\.identity_hash/)
      expect { recorder.start_span("balcao.turn").finish(attributes: { "system_prompt" => "You are" }) }
        .to raise_error(ArgumentError, /system_prompt/)
    end

    it "truncates text to 500 characters (FR-12)" do
      recorder.start_span("anthropic.custom_tool_use search_products",
                          attributes: { "anthropic.tool_result.content" => "x" * 600 })

      value = TraceEvent.sole.span_attributes["anthropic.tool_result.content"]
      expect(value.length).to eq(500)
      expect(value).to end_with("…")
    end

    it "stores text with a NUL or bytes that are not UTF-8, which jsonb refuses (review finding C4 of pull request #10)" do
      recorder.start_span("anthropic.custom_tool_use search_products",
                          attributes: { "gen_ai.tool.call.arguments" => "{\"query\":\"dipirona\u0000\"}",
                                        "anthropic.tool_result.content" => "caf\xC3".dup.force_encoding("BINARY") })

      expect(TraceEvent.sole.span_attributes).to eq("gen_ai.tool.call.arguments" => "{\"query\":\"dipirona\"}",
                                                    "anthropic.tool_result.content" => "caf�")
    end

    it "drops attributes whose value is nil" do
      recorder.start_span("balcao.turn", attributes: { "error.type" => nil, "balcao.channel" => "web" })

      expect(TraceEvent.sole.span_attributes).to eq("balcao.channel" => "web")
    end
  end

  describe "a trace that cannot be written" do
    it "logs the span's name and its error class, never its values, and the turn goes on" do
      allow(Rails.logger).to receive(:error)
      allow(TraceEvent).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, "PG::Error: value 'dipirona'")

      span = recorder.start_span("balcao.turn", attributes: { "balcao.channel" => "web" })
      expect { span.finish(attributes: { "balcao.turn.outcome" => "replied" }) }.not_to raise_error

      expect(Rails.logger).to have_received(:error).with(/balcao\.turn.*ActiveRecord::StatementInvalid/).at_least(:once)
      expect(Rails.logger).not_to have_received(:error).with(/dipirona/)
    end

    it "leaves the caller's transaction usable" do
      allow(Rails.logger).to receive(:error)
      allow(ActionCable.server).to receive(:broadcast)
      # A row the database refuses (a turn that is gone), not one a validation stops.
      allow(TraceEvent).to receive(:create!) { |**attributes| TraceEvent.new(**attributes, turn_id: SecureRandom.uuid).save!(validate: false) }

      ApplicationRecord.transaction do
        recorder.start_span("balcao.turn")
        expect(Turn.count).to eq(1)
      end
    end
  end

  describe "#abandon" do
    it "finishes every span still open, the innermost first, with the error" do
      root = recorder.start_span("balcao.turn")
      recorder.start_span("anthropic.messages.create", parent: root).finish
      recorder.start_span("balcao.outbound", parent: root)

      recorder.abandon("ActiveRecord::ConnectionFailed")

      expect(TraceEvent.where(finished_at: nil)).to be_empty
      expect(TraceEvent.where(name: %w[balcao.turn balcao.outbound]).map(&:span_attributes))
        .to all(eq("error.type" => "ActiveRecord::ConnectionFailed"))
      expect(TraceEvent.find_by(name: "anthropic.messages.create").span_attributes).to eq({})
    end
  end

  describe ".close_interrupted" do
    it "finishes the spans an interrupted run left open, marked as interrupted, and broadcasts them" do
      open_span = create(:trace_event, turn:, name: "anthropic.messages.create", span_attributes: { "gen_ai.request.model" => "claude-opus-5-5" })
      closed = create(:trace_event, turn:, name: "balcao.outbound", finished_at: 1.minute.ago)

      expect { TraceRecorder.close_interrupted(turn) }
        .to have_broadcasted_to("trace:#{conversation.trace_token}").with(a_hash_including(type: "span"))

      expect(open_span.reload.finished_at).to be_present
      expect(open_span.span_attributes).to include("gen_ai.request.model" => "claude-opus-5-5", "error.type" => "interrupted")
      expect(closed.reload.span_attributes).not_to have_key("error.type")
    end
  end
end
