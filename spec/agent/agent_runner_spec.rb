require "rails_helper"

RSpec.describe "design §6.3 AgentRunner (FR-02, FR-04, FR-14, SR-16, SR-19, SR-20, NFR-03)" do
  include ModelResponses

  let(:conversation) { create(:conversation) }
  let(:responses) { [ reply("[pt] Temos, sim.") ] }
  let(:fake) { FakeModel.new(responses) }
  let(:clock) { FakeClock.new }
  let(:runner) { AgentRunner.new(client: fake.client, tools: [ SpecTools::Echo ], clock:) }
  let(:turn) { turn_in(conversation, "tem dipirona?", at: Time.zone.local(2026, 11, 11, 15, 30)) }

  def turn_in(conversation, text, at:, reply: nil)
    travel_to(at) do
      turn = Turn.for_inbound!(create(:message, conversation:, body: text))
      Message.record_outbound!(turn:, body: reply) if reply
      turn
    end
  end

  def request(index = 0) = fake.requests.fetch(index)

  describe "the request (design §6.4, ADR-0003)" do
    it "sends the normal mode's model and effort, 1,500 output tokens and no thinking parameter" do
      runner.run(turn)

      expect(request.body).to include(model: "claude-opus-5-5", max_tokens: 1500, output_config: { effort: "medium" })
      expect(request.body).not_to have_key(:thinking)
    end

    it "asks for the server-side refusal fallback on the Opus route, with its beta header" do
      runner.run(turn)

      expect(request.body).to include(fallbacks: "default")
      expect(request.headers["anthropic-beta"]).to include("server-side-fallback-2026-07-01")
    end

    it "sends the economy mode's model with no fallback" do
      runner.run(turn, mode: "economy")

      expect(request.body).to include(model: "claude-haiku-5-5", output_config: { effort: "medium" })
      expect(request.body).not_to have_key(:fallbacks)
      expect(request.headers["anthropic-beta"].to_s).not_to include("server-side-fallback")
    end

    it "caches the system prompt, which comes after the tools, and the conversation's tail" do
      runner.run(turn)

      expect(request.body[:system]).to eq([ { type: "text", text: SystemPrompt.current, cache_control: { type: "ephemeral" } } ])
      expect(request.body[:cache_control]).to eq(type: "ephemeral")
    end

    it "sends each tool with its strict schema (SR-16)" do
      runner.run(turn)

      expect(request.body[:tools]).to contain_exactly(include(name: "echo", strict: true,
                                                              input_schema: include(additionalProperties: false)))
    end

    it "sends no tool list when the runner has no tools" do
      AgentRunner.new(client: fake.client, tools: [], clock:).run(turn)

      expect(request.body).not_to have_key(:tools)
    end

    # The owner's decision of 2026-11-14: the store's pharmacist works the
    # store's hours, and no instruction the model reads makes one "on duty".
    it "names the store's pharmacist, never one on duty, in the prompt and in the tools' descriptions" do
      AgentRunner.new(client: fake.client, clock:).run(turn)

      read = [ request.body[:system].sole[:text], *request.body[:tools].map { |tool| tool[:description] },
               Tools::GetStoreInfo::UNKNOWN, Tools::CreateReservation::OVER_LIMIT, Tools::CreateReservation::OUT_OF_STOCK ]
      expect(read.join("\n")).not_to match(/pharmacist on duty|on duty\)/i)
      expect(read.join("\n")).to include("the store's pharmacist")
    end

    it "refuses the paused mode, which never reaches the model" do
      expect { runner.run(turn, mode: "paused") }.to raise_error(ArgumentError)
      expect(fake.requests).to be_empty
    end
  end

  describe "the conversation it sends (FR-04)" do
    it "sends the conversation's turns oldest first, each visitor message with its São Paulo time" do
      turn_in(conversation, "tem dipirona?", at: Time.zone.local(2026, 11, 11, 15, 0), reply: "Temos, R$ 8,90.")
      current = turn_in(conversation, "e quanto custa?", at: Time.zone.local(2026, 11, 11, 15, 2))

      runner.run(current)

      expect(request.body[:messages]).to eq([
        { role: "user", content: [ { type: "text", text: "Sent Wednesday, 2026-11-11 15:00 (São Paulo time)" },
                                   { type: "text", text: "tem dipirona?" } ] },
        { role: "assistant", content: [ { type: "text", text: "Temos, R$ 8,90." } ] },
        { role: "user", content: [ { type: "text", text: "Sent Wednesday, 2026-11-11 15:02 (São Paulo time)" },
                                   { type: "text", text: "e quanto custa?" } ] }
      ])
    end

    it "leaves out turns that arrived after the one it runs" do
      current = turn_in(conversation, "tem dipirona?", at: Time.zone.local(2026, 11, 11, 15, 0))
      turn_in(conversation, "e paracetamol?", at: Time.zone.local(2026, 11, 11, 15, 1))

      runner.run(current)

      expect(request.body[:messages].to_s).not_to include("paracetamol")
    end

    it "leaves out the conversation's other visitors and closed conversations" do
      other = create(:conversation)
      turn_in(other, "segredo de outra pessoa", at: Time.zone.local(2026, 11, 11, 14, 0), reply: "ok")

      runner.run(turn)

      expect(request.body[:messages].to_s).not_to include("segredo")
    end

    it "keeps the last 30 turns and drops the oldest" do
      start = Time.zone.local(2026, 11, 11, 8, 0)
      31.times { |n| turn_in(conversation, "mensagem #{n}", at: start + n.minutes, reply: "resposta #{n}") }
      current = turn_in(conversation, "a última", at: start + 31.minutes)

      runner.run(current)

      users = request.body[:messages].select { |message| message[:role] == "user" }
      expect(users.size).to eq(30)
      expect(request.body[:messages].to_s).not_to include("mensagem 1\"")
      expect(request.body[:messages].first[:content].last[:text]).to eq("mensagem 2")
    end

    it "joins visitor messages that got no reply into one user message" do
      turn_in(conversation, "oi", at: Time.zone.local(2026, 11, 11, 15, 0))
      current = turn_in(conversation, "tem dipirona?", at: Time.zone.local(2026, 11, 11, 15, 1))

      runner.run(current)

      expect(request.body[:messages].size).to eq(1)
      expect(request.body[:messages].first[:content].pluck(:text)).to include("oi", "tem dipirona?")
    end
    it "leaves out the demo notice the system put before the first reply, which the model never writes (FR-01)" do
      first = turn_in(conversation, "hola", at: Time.zone.local(2026, 11, 11, 15, 0), reply: FixedReply.with_notice("¡Hola!", "es"))
      second = turn_in(conversation, "¿tienen dipirona?", at: Time.zone.local(2026, 11, 11, 15, 1))

      runner.run(second)

      expect(first.outbound_message.body).to start_with(FixedReply.notice("es"))
      expect(request.body[:messages][1]).to eq(role: "assistant", content: [ { type: "text", text: "¡Hola!" } ])
    end

    # Review finding R3 of pull request #17: the notice is told by its place,
    # the first line of the conversation's first reply, not by today's
    # wording, which a later deploy may change.
    it "leaves out a notice stored under an earlier wording, and keeps a later reply whole (FR-01)" do
      turn_in(conversation, "hola", at: Time.zone.local(2026, 11, 11, 15, 0),
                                    reply: "Aviso: una redacción anterior del aviso.\n\n¡Hola!")
      turn_in(conversation, "¿y gotas?", at: Time.zone.local(2026, 11, 11, 15, 1),
                                        reply: "Tenemos dos.\n\n¿Cuál prefieres?")
      third = turn_in(conversation, "la primera", at: Time.zone.local(2026, 11, 11, 15, 2))

      runner.run(third)

      expect(request.body[:messages][1]).to eq(role: "assistant", content: [ { type: "text", text: "¡Hola!" } ])
      expect(request.body[:messages][3]).to eq(role: "assistant", content: [ { type: "text", text: "Tenemos dos.\n\n¿Cuál prefieres?" } ])
    end
  end

  describe "the reply (FR-02)" do
    it "returns the reply without its language tag, and the language the tag names" do
      result = runner.run(turn)

      expect(result).to have_attributes(outcome: :replied, text: "Temos, sim.", language: "pt-BR")
    end

    context "when the reply is in Spanish" do
      let(:responses) { [ reply("[es] ¡Sí, hacemos entregas!") ] }

      it "names Spanish" do
        expect(runner.run(turn)).to have_attributes(text: "¡Sí, hacemos entregas!", language: "es")
      end
    end

    context "when the reply carries no tag" do
      let(:responses) { [ reply("Temos, sim.") ] }

      it "returns the text whole and no language, so the conversation keeps its own" do
        expect(runner.run(turn)).to have_attributes(outcome: :replied, text: "Temos, sim.", language: nil)
      end
    end

    # Review finding C1 of pull request #9: text the model writes in a step
    # that also calls a tool is part of the reply, and may carry the tag or
    # the declined clinical part (FR-09).
    context "when the model writes text before calling a tool" do
      let(:responses) do
        [ message(content: [ thinking, text("[es] Déjame ver."), tool_use("echo", { "text" => "x" }) ], stop_reason: :tool_use),
          reply("Sí, hacemos entregas.") ]
      end

      it "keeps that text in the reply, in order, and reads the language from its tag" do
        expect(runner.run(turn)).to have_attributes(outcome: :replied, text: "Déjame ver.\n\nSí, hacemos entregas.",
                                                    language: "es")
      end
    end

    context "when a later step repeats the tag" do
      let(:responses) do
        [ message(content: [ text("[pt] Não posso indicar dose; o farmacêutico responde no balcão."),
                             tool_use("echo", { "text" => "dipirona" }) ], stop_reason: :tool_use),
          reply("[pt] Temos dipirona.") ]
      end

      it "shows no tag and keeps the declined part (FR-09)" do
        expect(runner.run(turn).text).to eq("Não posso indicar dose; o farmacêutico responde no balcão.\n\nTemos dipirona.")
      end
    end
  end

  # FR-10's MVP note: the offer of the pharmacist is a fixed line, which the
  # caller adds where the model's tag asks for it (TurnProcessor); the tag
  # itself never reaches the visitor.
  describe "the offer of the pharmacist (FR-09, FR-10's MVP note)" do
    it "asks for no offer when the reply carries no tag" do
      expect(runner.run(turn)).to have_attributes(outcome: :replied, text: "Temos, sim.", offer: false)
    end

    context "when the reply ends with the offer's tag" do
      let(:responses) { [ reply("[pt] Isso eu não posso responder; quem responde é o farmacêutico da loja. [pharmacist]") ] }

      it "returns the reply without the tag, and asks for the offer" do
        expect(runner.run(turn)).to have_attributes(
          outcome: :replied, language: "pt-BR", offer: true,
          text: "Isso eu não posso responder; quem responde é o farmacêutico da loja."
        )
      end
    end

    context "when the tag stands on a line of its own, capitalised" do
      let(:responses) { [ reply("[en] I can't answer that here.\n[Pharmacist]") ] }

      it "removes it all the same" do
        expect(runner.run(turn)).to have_attributes(text: "I can't answer that here.", offer: true)
      end
    end

    context "when the text before a tool call carries it" do
      let(:responses) do
        [ message(content: [ text("[pt] Dose eu não posso indicar. [pharmacist]"), tool_use("echo", { "text" => "dipirona" }) ],
                  stop_reason: :tool_use),
          reply("[pt] Temos dipirona.") ]
      end

      it "asks for the offer once and shows no tag" do
        expect(runner.run(turn)).to have_attributes(text: "Dose eu não posso indicar.\n\nTemos dipirona.", offer: true)
      end
    end

    context "when the tag sits inside a sentence" do
      let(:responses) { [ reply("[pt] Fale com o farmacêutico [pharmacist] no balcão.") ] }

      it "leaves one space where it was" do
        expect(runner.run(turn)).to have_attributes(text: "Fale com o farmacêutico no balcão.", offer: true)
      end
    end

    # Review finding C1 of pull request #27: a reply that is its tags alone
    # asks for the line all the same, and the line is the reply; only a reply
    # with no text and no tag is empty (NFR-03).
    context "when the reply is the tag alone" do
      let(:responses) { [ reply("[pt] [pharmacist]") ] }

      it "is a reply with no text of its own that asks for the offer" do
        expect(runner.run(turn)).to have_attributes(outcome: :replied, text: "", language: "pt-BR", offer: true)
      end
    end

    context "when the reply has neither text nor tag" do
      let(:responses) { [ reply("[pt] ") ] }

      it "ends as an empty reply does, for the fallback (NFR-03)" do
        expect(runner.run(turn)).to have_attributes(outcome: :incomplete, text: nil, offer: false)
      end
    end
  end

  # FR-09, the owner's decision of 2026-11-14: a message that may be an
  # emergency gets a fixed line with the public emergency numbers, which the
  # caller adds where the model's tag asks for it.
  describe "the emergency line (FR-09)" do
    it "asks for no emergency line when the reply carries no tag" do
      expect(runner.run(turn)).to have_attributes(emergency: false)
    end

    context "when the reply ends with the emergency's tag" do
      let(:responses) { [ reply("[pt] Ligue agora para o socorro. [emergency]") ] }

      it "returns the reply without the tag, and asks for the emergency line" do
        expect(runner.run(turn)).to have_attributes(outcome: :replied, text: "Ligue agora para o socorro.", emergency: true,
                                                    offer: false)
      end
    end

    context "when the reply is the emergency's tag alone (review finding C1 of pull request #27)" do
      let(:responses) { [ reply("[pt] [emergency]") ] }

      it "is a reply with no text of its own that asks for the emergency line" do
        expect(runner.run(turn)).to have_attributes(outcome: :replied, text: "", emergency: true)
      end
    end

    context "when the reply carries both tags" do
      let(:responses) { [ reply("[en] Call for help now. [EMERGENCY]\n[pharmacist]") ] }

      it "removes both and asks for both lines, which the caller orders" do
        expect(runner.run(turn)).to have_attributes(text: "Call for help now.", emergency: true, offer: true)
      end
    end
  end

  describe "the tool loop (design §6.3)" do
    let(:responses) { [ tool_turn(tool_use("echo", { "text" => "dipirona" })), reply("[pt] Temos dipirona.") ] }

    it "runs the tool the model calls and answers with the model's next reply" do
      result = runner.run(turn)

      expect(result).to have_attributes(outcome: :replied, text: "Temos dipirona.")
      expect(result.tool_calls).to contain_exactly(have_attributes(name: "echo", input: { "text" => "dipirona" },
                                                                   is_error: false))
    end

    it "gives the tool the runner's turn, never one the model names (SR-16)" do
      runner.run(turn)

      result_block = request(1).body[:messages].last[:content].first
      expect(JSON.parse(result_block[:content])).to eq("echo" => "dipirona", "turn_id" => turn.id)
    end

    it "reports each step as it happens, for the trace (FR-12)" do
      events = []
      runner.run(turn) { |event| events << event }

      expect(events.map(&:class)).to eq([ AgentRunner::ModelStarted, AgentRunner::ModelCall, AgentRunner::ToolCall,
                                          AgentRunner::ModelStarted, AgentRunner::ModelCall ])
      expect(events.first).to have_attributes(model: "claude-opus-5-5", effort: "medium")
    end

    it "measures each model call" do
      result = runner.run(turn)

      expect(result.model_calls).to all(have_attributes(model: "claude-opus-5-5", latency_ms: a_value >= 0, error: nil))
      expect(result.model_calls.map(&:stop_reason)).to eq(%w[tool_use end_turn])
    end
  end

  describe "the limits of SR-20" do
    def echo = tool_use("echo", { "text" => "x" })

    context "when the model asks for a seventh tool call" do
      let(:responses) { Array.new(7) { tool_turn(echo) } }

      it "stops before running it and returns no text" do
        result = runner.run(turn)

        expect(result).to have_attributes(outcome: :tool_limit, text: nil)
        expect(result.tool_calls.size).to eq(6)
        expect(fake.requests.size).to eq(7)
      end
    end

    context "when parallel calls would cross six" do
      let(:responses) { [ tool_turn(echo, echo, echo, echo), tool_turn(echo, echo, echo) ] }

      it "runs the calls up to the sixth and none after it" do
        result = runner.run(turn)

        expect(result).to have_attributes(outcome: :tool_limit, text: nil)
        expect(result.tool_calls.size).to eq(6)
        expect(fake.requests.size).to eq(2)
      end
    end

    # A tool that takes `seconds` of the turn's clock.
    def slow_echo(seconds)
      elapsed = clock
      stub_const("SlowEcho", Class.new(AgentTool) do
        doc "Echoes the text back, slowly."
        input_schema SpecTools::EchoInput
        define_method(:perform) do |input|
          elapsed.advance(seconds)
          { "echo" => input.text }
        end
      end)
    end

    def slow_turn = tool_turn(tool_use("slow_echo", { "text" => "x" }))

    context "when the turn's wall clock runs out" do
      let(:responses) { [ slow_turn, reply("[pt] tarde demais") ] }

      it "asks the model nothing more and returns no text" do
        result = AgentRunner.new(client: fake.client, tools: [ slow_echo(61) ], clock:).run(turn)

        expect(result).to have_attributes(outcome: :deadline, text: nil)
        expect(fake.requests.size).to eq(1)
      end
    end

    context "when earlier steps took part of it" do
      let(:responses) { [ slow_turn, reply("[pt] pronto") ] }

      it "gives each request only the time left" do
        AgentRunner.new(client: fake.client, tools: [ slow_echo(25) ], clock:).run(turn)

        expect(fake.requests.map { |sent| sent.options[:timeout] }).to eq([ 60, 35 ])
      end
    end
  end

  describe "model errors (NFR-03, SR-19)" do
    context "when the API answers 529 three times" do
      let(:responses) { Array.new(3) { error(:overloaded) } }

      it "ends the turn as a model error with the SDK's class, after the SDK's three attempts" do
        result = runner.run(turn)

        expect(result).to have_attributes(outcome: :model_error, text: nil, error: an_instance_of(Anthropic::Errors::OverloadedError))
        expect(fake.requests.size).to eq(3)
      end

      it "reports the failed model call with its error, for the trace" do
        events = []
        result = runner.run(turn) { |event| events << event }

        expect(result.model_calls).to contain_exactly(have_attributes(error: "Anthropic::Errors::OverloadedError", usage: []))
        expect(events.last).to be_a(AgentRunner::ModelCall).and(have_attributes(error: "Anthropic::Errors::OverloadedError"))
      end
    end

    # Review finding C2 of pull request #9: the SDK sleeps as long as a
    # response's retry-after asks, so the wait must fit the turn (SR-20).
    describe "a retry the API asks to wait for" do
      let(:delays) { [] }
      let(:client) do
        fake.client.tap do |client|
          allow(client).to receive(:sleep) { |seconds| delays << seconds && clock.advance(seconds) }
        end
      end
      let(:runner) { AgentRunner.new(client:, tools: [ SpecTools::Echo ], clock:) }

      context "when the wait outlasts what is left of the turn" do
        let(:responses) { [ error(:rate_limit).merge(headers: { "retry-after" => "120" }), reply("[pt] tarde") ] }

        it "is not made, and the turn ends with the API's error" do
          result = runner.run(turn)

          expect(result).to have_attributes(outcome: :model_error, error: an_instance_of(Anthropic::Errors::RateLimitError))
          expect(delays).to be_empty
          expect(fake.requests.size).to eq(1)
        end
      end

      context "when the wait in milliseconds outlasts it" do
        let(:responses) { [ error(:overloaded).merge(headers: { "retry-after-ms" => "61000" }), reply("[pt] tarde") ] }

        it "is not made either" do
          expect(runner.run(turn)).to have_attributes(outcome: :model_error)
          expect(delays).to be_empty
        end
      end

      context "when the wait is an HTTP date past the turn" do
        let(:responses) { [ error(:rate_limit).merge(headers: { "retry-after" => 2.minutes.from_now.httpdate }), reply("[pt] tarde") ] }

        it "is not made either" do
          expect(runner.run(turn)).to have_attributes(outcome: :model_error)
          expect(delays).to be_empty
        end
      end

      context "when the wait fits" do
        let(:responses) { [ error(:rate_limit).merge(headers: { "retry-after" => "2" }), reply("[pt] Pronto.") ] }

        it "is made, as the SDK makes it" do
          expect(runner.run(turn)).to have_attributes(outcome: :replied, text: "Pronto.")
          expect(delays).to eq([ 2.0 ])
        end
      end
    end

    context "when an error follows a tool call" do
      let(:responses) { [ tool_turn(tool_use("echo", { "text" => "x" })), *Array.new(3) { error(:overloaded) } ] }

      it "keeps the calls made before it, with their usage" do
        result = runner.run(turn)

        expect(result).to have_attributes(outcome: :model_error)
        expect(result.tool_calls.size).to eq(1)
        expect(result.model_calls.first.usage).to be_present
      end
    end

    context "when the model refuses" do
      let(:responses) { [ refusal ] }

      it "ends without text, which the decline text replaces (SR-19)" do
        expect(runner.run(turn)).to have_attributes(outcome: :refused, text: nil)
      end
    end
  end

  describe "usage, for the budget (FR-14)" do
    let(:responses) { [ reply("[pt] Temos.", usage: usage(input: 900, output: 60, cache_write: 3100, cache_read: 0)) ] }

    it "reports the usage of every model call with the model that ran it" do
      result = runner.run(turn)

      expect(result.model_calls.first.usage).to eq([
        AgentRunner::Usage.new(model: "claude-opus-5-5", input_tokens: 900, output_tokens: 60,
                               cache_creation_tokens: 3100, cached_tokens: 0)
      ])
    end

    context "when a fallback model served the call" do
      let(:responses) do
        iterations = [ iteration(model: "claude-opus-5-5", input: 900, output: 0),
                       iteration(model: "claude-opus-5", input: 950, output: 70, fallback: true) ]
        [ reply("[pt] Temos.", model: "claude-opus-5", usage: usage(input: 950, output: 70, iterations:)) ]
      end

      it "reports each attempt from usage.iterations, each with its own model" do
        result = runner.run(turn)

        expect(result.model_calls.first.usage.map { |usage| [ usage.model, usage.input_tokens, usage.output_tokens ] })
          .to eq([ [ "claude-opus-5-5", 900, 0 ], [ "claude-opus-5", 950, 70 ] ])
      end
    end
  end
end
