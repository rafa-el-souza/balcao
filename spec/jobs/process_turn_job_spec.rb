require "rails_helper"

RSpec.describe "design §6.3 ProcessTurnJob, one turn from its inbound message to its reply (FR-01, FR-02, FR-12, NFR-02, NFR-03)" do
  include ModelResponses

  let(:visitor) { create(:visitor) }
  let(:conversation) { create(:conversation, visitor:) }
  let(:responses) { [ reply("[pt] Olá! Posso ajudar com um produto, um preço ou uma entrega.") ] }
  let(:fake) { FakeModel.new(responses) }

  before { allow(AgentRunner).to receive(:default_client) { fake.client } }

  def inbound(text, conversation: self.conversation, at: Time.current)
    travel_to(at) do
      message = Message.record_inbound!(conversation:, external_id: SecureRandom.uuid, body: text)
      Turn.for_inbound!(message)
    end
  end

  def perform(turn) = ProcessTurnJob.perform_now(turn.id)

  def spans(turn) = TraceEvent.where(turn_id: turn.id).order(:started_at, :created_at)

  describe "a turn the model answers" do
    it "replies with the model's text, marks the turn replied and records the mode, the model and the latency" do
      turn = inbound("oi", at: 2.seconds.ago)

      perform(turn)

      expect(turn.reload).to have_attributes(state: "replied", mode: "normal", model: "claude-opus-5-5",
                                             latency_ms: a_value >= 2000)
      expect(turn.outbound_message.body).to end_with("Olá! Posso ajudar com um produto, um preço ou uma entrega.")
    end

    it "sends the reply to the conversation's stream" do
      turn = inbound("oi")

      expect { perform(turn) }.to have_broadcasted_to("conversation:#{conversation.id}")
        .with(a_hash_including(type: "message", message: a_hash_including(conversation_id: conversation.id, turn_id: turn.id,
                                                                            author: "bot", body: a_string_ending_with("entrega."))))
    end
  end

  describe "the demo notice (FR-01) and the language (FR-02)" do
    it "puts the notice before the first reply of a conversation, in the language the reply names" do
      responses.replace([ reply("[es] ¡Hola! ¿Buscas algún producto?") ])
      turn = inbound("hola")

      perform(turn)

      expect(turn.outbound_message.body).to eq(FixedReply.with_notice("¡Hola! ¿Buscas algún producto?", "es"))
      expect(conversation.reload.language).to eq("es")
    end

    it "does not repeat the notice on later turns" do
      responses.replace([ reply("[pt] Olá!"), reply("[pt] Temos, sim.") ])
      perform(inbound("oi"))
      turn = inbound("tem dipirona?")

      perform(turn)

      expect(turn.outbound_message.body).to eq("Temos, sim.")
    end

    it "keeps the conversation's language when the reply names none" do
      conversation.update!(language: "en")
      responses.replace([ reply("Ok!") ])
      turn = inbound("ok")

      perform(turn)

      expect(conversation.reload.language).to eq("en")
      expect(turn.outbound_message.body).to eq(FixedReply.with_notice("Ok!", "en"))
    end
  end

  describe "a turn run again (NFR-02)" do
    it "calls, bills and traces nothing when the turn has its reply" do
      turn = inbound("oi")
      perform(turn)
      counts = [ fake.requests.size, Message.count, TraceEvent.count, UsageRecord.count ]

      expect { perform(turn) }.not_to have_broadcasted_to("conversation:#{conversation.id}")
      expect([ fake.requests.size, Message.count, TraceEvent.count, UsageRecord.count ]).to eq(counts)
    end

    it "answers a turn whose reservation an earlier run stored with the reservation's line, without the model" do
      turn = inbound("quero reservar duas dipironas")
      reservation = create(:reservation, turn:, quantity: 2)
      responses.clear

      perform(turn)

      expect(fake.requests).to be_empty
      expect(turn.reload.state).to eq("replied")
      expect(turn.outbound_message.body).to eq(FixedReply.with_notice(FixedReply.reservations([ reservation ], "pt-BR"), "pt-BR"))
      expect(spans(turn).first.span_attributes).to include("balcao.turn.outcome" => "reservations")
    end

    it "finishes the spans an interrupted run left open before it runs the turn again" do
      turn = inbound("oi")
      left_open = create(:trace_event, turn:, name: "anthropic.messages.create")

      perform(turn)

      expect(left_open.reload).to have_attributes(finished_at: be_present,
                                                  span_attributes: include("error.type" => "interrupted"))
    end
  end

  describe "a turn the model cannot answer (NFR-03, SR-19, SR-20)" do
    it "replies with the fallback text, marks the turn failed and records the error on the model call's span" do
      responses.replace(Array.new(3) { error(:overloaded) })
      conversation.update!(language: "en")
      turn = inbound("hello")

      perform(turn)

      expect(fake.requests.size).to eq(3)
      expect(turn.reload.state).to eq("failed")
      expect(turn.outbound_message.body).to eq(FixedReply.with_notice(FixedReply.fallback("en"), "en"))
      model_span = spans(turn).find_by(name: "anthropic.messages.create")
      expect(model_span.span_attributes).to include("error.type" => "Anthropic::Errors::OverloadedError")
      expect(spans(turn).first.span_attributes).to include("balcao.turn.outcome" => "model_error")
    end

    it "carries the line of a reservation stored before the error" do
      create(:product, sku: "DIP-500")
      allow(AgentRunner).to receive(:new).and_wrap_original { |original, **options| original.call(**options, tools: [ SpecTools::Reserve ]) }
      responses.replace([ tool_turn(tool_use("reserve", { text: "DIP-500" })), *Array.new(3) { error(:overloaded) } ])
      turn = inbound("reserva duas dipironas")

      perform(turn)

      reservation = turn.reservations.sole
      expect(turn.reload.state).to eq("failed")
      expect(turn.outbound_message.body).to end_with(FixedReply.with_reservations(FixedReply.fallback("pt-BR"), [ reservation ], "pt-BR"))
    end

    it "answers a refusal with the decline text, never with the model's output" do
      responses.replace([ refusal ])
      turn = inbound("como faço para ...")

      perform(turn)

      expect(turn.reload.state).to eq("replied")
      expect(turn.outbound_message.body).to eq(FixedReply.with_notice(FixedReply.declined("pt-BR"), "pt-BR"))
      expect(spans(turn).first.span_attributes).to include("balcao.turn.outcome" => "refused")
    end

    it "marks the turn failed, closes its spans and raises when the turn breaks outside the model" do
      turn = inbound("oi")
      allow(Message).to receive(:record_outbound!).and_raise(ActiveRecord::ConnectionFailed, "gone")

      expect { perform(turn) }.to raise_error(ActiveRecord::ConnectionFailed)

      expect(turn.reload.state).to eq("failed")
      expect(spans(turn).where(finished_at: nil)).to be_empty
      expect(spans(turn).first.span_attributes).to include("error.type" => "ActiveRecord::ConnectionFailed")
    end
  end

  describe "the trace (FR-12, ADR-0010)" do
    let(:product) { create(:product, name: "Dipirona 500 mg, 10 comprimidos", active_ingredient: "dipirona") }
    let(:responses) do
      [ tool_turn(tool_use("search_products", { query: "dipirona" })),
        reply("[pt] Temos Dipirona 500 mg por R$ 8,90.", usage: usage(input: 1300, output: 60, cache_write: 10, cache_read: 2900)) ]
    end

    before { product }

    it "records the turn as a root span from the message's receipt, with the model calls, the tool call and the outbound message under it" do
      received = 3.seconds.ago.change(usec: 0)
      turn = inbound("tem dipirona?", at: received)

      perform(turn)

      names = spans(turn).map(&:name)
      expect(names).to eq([ "balcao.turn", "anthropic.messages.create", "anthropic.custom_tool_use search_products",
                            "anthropic.messages.create", "balcao.outbound" ])
      root, *children = spans(turn).to_a
      expect(root.started_at).to eq(received)
      expect(children.map(&:parent_span_id)).to all(eq(root.span_id))
      expect(spans(turn).map(&:trace_id).uniq.size).to eq(1)
      expect(spans(turn).where(finished_at: nil)).to be_empty
      expect(root.span_attributes).to include("balcao.channel" => "web", "balcao.message.source" => "text",
                                              "balcao.turn.mode" => "normal", "balcao.turn.outcome" => "replied")
    end

    it "shows each model call's model, effort and usage (FR-12)" do
      turn = inbound("tem dipirona?")

      perform(turn)

      call = spans(turn).where(name: "anthropic.messages.create").last
      expect(call.span_attributes).to include(
        "gen_ai.operation.name" => "chat", "gen_ai.provider.name" => "anthropic",
        "gen_ai.request.model" => "claude-opus-5-5", "gen_ai.request.reasoning.level" => "medium",
        "gen_ai.request.max_tokens" => 1500, "gen_ai.response.model" => "claude-opus-5-5",
        "anthropic.message.stop_reason" => "end_turn",
        "gen_ai.usage.input_tokens" => 1300, "gen_ai.usage.output_tokens" => 60,
        "gen_ai.usage.cache_read.input_tokens" => 2900, "gen_ai.usage.cache_write.input_tokens" => 10,
        "balcao.latency_ms" => a_kind_of(Integer)
      )
    end

    it "summarises the system prompt by size and digest, never its text (SR-12)" do
      turn = inbound("tem dipirona?")

      perform(turn)

      call = spans(turn).find_by(name: "anthropic.messages.create")
      expect(call.span_attributes).to include("balcao.system_prompt.characters" => SystemPrompt.current.length,
                                              "balcao.system_prompt.sha256" => Digest::SHA256.hexdigest(SystemPrompt.current)[0, 16])
    end

    it "shows each tool call with its arguments and result" do
      turn = inbound("tem dipirona?")

      perform(turn)

      tool = spans(turn).find_by(name: "anthropic.custom_tool_use search_products")
      expect(tool.span_attributes).to include("gen_ai.operation.name" => "execute_tool", "gen_ai.tool.name" => "search_products",
                                              "gen_ai.tool.type" => "function",
                                              "gen_ai.tool.call.arguments" => '{"query":"dipirona"}',
                                              "anthropic.tool_result.content" => a_string_including("Dipirona 500 mg"))
      expect(tool.span_attributes).not_to have_key("error.type")
    end

    it "records a tool call whose input carries a NUL, and the turn completes (review finding C4 of pull request #10)" do
      responses[0] = tool_turn(tool_use("search_products", { query: "dipirona\u0000" }))
      turn = inbound("tem dipirona?")

      perform(turn)

      expect(turn.reload.state).to eq("replied")
      tool = spans(turn).find_by(name: "anthropic.custom_tool_use search_products")
      expect(tool.span_attributes["gen_ai.tool.call.arguments"]).to eq('{"query":"dipirona"}')
    end

    # The raw phone and the BSUID join the list with the WhatsApp channel (PR-18).
    it "carries no secret, no identity and no system prompt in any span or broadcast (SR-12)" do
      turn = inbound("tem dipirona?")
      broadcasts = []
      allow(ActionCable.server).to receive(:broadcast) { |stream, payload| broadcasts << [ stream, payload ] }

      perform(turn)

      written = spans(turn).map { |span| span.attributes.to_json }.join + broadcasts.map(&:last).to_json
      # "fake-model" is the API key FakeModel's client sends.
      forbidden = [ "fake-model", Rails.application.secret_key_base, visitor.identity_hash,
                    conversation.trace_token, SystemPrompt.current[0, 80], Tools::SearchProducts.doc_string[0, 80] ]
      expect(forbidden).to all(be_present)
      expect(forbidden.select { |value| written.include?(value) }).to be_empty
    end
  end

  describe "turns of one conversation, in arrival order (design §6.3)" do
    it "answers an earlier turn still waiting before its own, so the model sees the earlier reply" do
      responses.replace([ reply("[pt] Olá!"), reply("[pt] Temos, sim.") ])
      first = inbound("oi", at: 2.seconds.ago)
      second = inbound("tem dipirona?", at: 1.second.ago)

      perform(second)

      expect([ first.reload.state, second.reload.state ]).to eq(%w[replied replied])
      expect(first.outbound_message.created_at).to be < second.outbound_message.created_at
      expect(fake.requests.last.body[:messages].map { |message| message[:role] }).to eq(%w[user assistant user])
      expect { perform(first) }.not_to(change { fake.requests.size })
    end

    it "leaves an earlier turn that failed to its own job" do
      first = inbound("oi", at: 2.seconds.ago)
      first.update!(state: "failed")
      second = inbound("tem dipirona?", at: 1.second.ago)

      perform(second)

      expect(first.reload.outbound_message).to be_nil
      expect(second.reload.state).to eq("replied")
    end

    it "answers its own turn when an earlier one breaks" do
      allow(Rails.logger).to receive(:error)
      first = inbound("oi", at: 2.seconds.ago)
      second = inbound("tem dipirona?", at: 1.second.ago)
      calls = 0
      original = Message.method(:record_outbound!)
      allow(Message).to receive(:record_outbound!) do |**arguments|
        calls += 1
        raise ActiveRecord::ConnectionFailed, "gone" if calls == 1

        original.call(**arguments)
      end
      responses.replace([ reply("[pt] Olá!"), reply("[pt] Temos, sim.") ])

      perform(second)

      expect(first.reload.state).to eq("failed")
      expect(second.reload.state).to eq("replied")
      expect(Rails.logger).to have_received(:error).with(/earlier turn #{first.id}.*ActiveRecord::ConnectionFailed/)
    end

    it "does nothing for a turn deleted with its visitor before the job ran (FR-05)" do
      turn = inbound("oi")
      visitor.erase!

      expect { perform(turn) }.not_to raise_error
      expect(fake.requests).to be_empty
    end
  end

  describe "the commands, matched before the model (FR-04, FR-05, FR-12)" do
    before { responses.clear }

    describe "reset (FR-04)" do
      it "closes the conversation, opens a new one and confirms in it with the notice, without the model" do
        responses.replace([ reply("[pt] Olá!") ])
        perform(inbound("oi"))
        turn = inbound("/reiniciar")

        expect { perform(turn) }.to have_broadcasted_to("conversation:#{conversation.id}")
          .with(a_hash_including(type: "message", message: a_hash_including(conversation_id: satisfy { |id| id != conversation.id })))

        expect(fake.requests.size).to eq(1)
        expect(conversation.reload.closed_at).to be_present
        fresh = Conversation.current_for!(visitor)
        expect(fresh).not_to eq(conversation)
        expect(turn.reload).to have_attributes(state: "replied", outbound_message: have_attributes(conversation: fresh))
        expect(turn.outbound_message.body).to eq(FixedReply.with_notice(FixedReply.command(:reset, "pt-BR"), "pt-BR"))
        expect(turn.inbound_message.source).to eq("command")
      end

      it "records the command and nothing else in the trace" do
        turn = inbound("recomeçar")

        perform(turn)

        expect(spans(turn).map(&:name)).to eq([ "balcao.command" ])
        expect(spans(turn).sole).to have_attributes(finished_at: be_present,
                                                    span_attributes: { "balcao.command.name" => "reset" })
      end

      it "answers in the language of a phrase only one language lists, and the new conversation keeps it (FR-02)" do
        turn = inbound("start over")

        perform(turn)

        expect(turn.outbound_message.body).to eq(FixedReply.with_notice(FixedReply.command(:reset, "en"), "en"))
        expect(Conversation.current_for!(visitor).language).to eq("en")
      end

      it "opens no third conversation for a reset sent twice, and gives the notice once" do
        first = inbound("/reiniciar")
        second = inbound("/reiniciar")

        perform(first)
        perform(second)

        expect(visitor.conversations.count).to eq(2)
        expect(second.reload.outbound_message.body).to eq(FixedReply.command(:reset, "pt-BR"))
      end
    end

    describe "delete (FR-05)" do
      it "deletes the visitor's data, releases the reserved stock and confirms on the conversation's stream, without the model" do
        product = create(:product, stock: 10)
        earlier = inbound("oi")
        create(:reservation, turn: earlier, product:, quantity: 2)
        turn = inbound("apagar meus dados")

        expect { perform(turn) }.to have_broadcasted_to("conversation:#{conversation.id}")
          .with(type: "deleted", text: FixedReply.command(:delete, "pt-BR"))

        expect(fake.requests).to be_empty
        expect(Visitor.exists?(visitor.id)).to be(false)
        expect([ Conversation, Message, Turn, TraceEvent, Reservation ].map(&:count)).to all(eq(0))
        expect(product.reload.stock).to eq(12)
      end

      it "confirms in the language of the phrase" do
        turn = inbound("Delete my data.")

        expect { perform(turn) }.to have_broadcasted_to("conversation:#{conversation.id}")
          .with(type: "deleted", text: FixedReply.command(:delete, "en"))
      end

      it "is not matched inside a longer message, which goes to the model" do
        responses.replace([ reply("[pt] Tudo bem, não apago nada.") ])
        turn = inbound("não quero apagar meus dados")

        perform(turn)

        expect(fake.requests.size).to eq(1)
        expect(Visitor.exists?(visitor.id)).to be(true)
      end
    end

    describe "trace (FR-12)" do
      %w[/trace como\ você\ funciona?].each do |text|
        it "answers #{text.inspect} with the link to the conversation's trace page, without the model" do
          turn = inbound(text)

          perform(turn)

          url = "#{Rails.configuration.x.public_origin}/trace/#{conversation.trace_token}"
          expect(fake.requests).to be_empty
          expect(turn.reload.outbound_message.body).to eq(FixedReply.with_notice(FixedReply.command(:trace, "pt-BR", url:), "pt-BR"))
          expect(spans(turn).sole.span_attributes).to eq("balcao.command.name" => "trace")
        end
      end
    end
  end
end
