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

      expect(request.body).to include(model: "claude-opus-5-5", max_tokens: 1500, output_config: { effort: "low" })
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

    # M2-11a (design §10, M2-4's note; the owner, 2026-11-20: "(d) Só o que
    # o modelo escreveu" and "Aviso de uma frase"): the history gave the model
    # back its earlier replies with the system's fixed lines in them, which
    # the prompt tells it never to write, and the economy model once disowned
    # the offer's line ("o telefone e os horários que escrevi não vieram do
    # sistema"). An earlier reply is now what the model wrote, its tags
    # included, which say what lines the system added; no text of the
    # system's comes back. A first draft gave it back under a line in the
    # user's turn, which a visitor copied to forge a reservation the economy
    # model confirmed; a second, in a system message, which carries the
    # system prompt's authority, and the economy model then answered an
    # English-speaking visitor in Portuguese 11 times in 18 (the slice's own
    # probe). When the system answered in the model's place, one fixed
    # sentence in a system message says so, never the text the visitor read.
    describe "what the model wrote, and the system's notices" do
      def answered(text, at:, body:, kind: "model", written: nil)
        turn_in(conversation, text, at:).tap do |turn|
          travel_to(at + 5.seconds) do
            Message.record_outbound!(turn:, body:)
            turn.update!(reply_kind: kind, model_reply: written)
          end
        end
      end

      def sent(minute) = { type: "text", text: "Sent Wednesday, 2026-11-11 15:0#{minute} (São Paulo time)" }

      def notice(kind, minute)
        format(AgentRunner::History::NOTICES.fetch(kind), sent: "Wednesday, 2026-11-11 15:0#{minute} (São Paulo time)")
      end

      def written = request.body[:messages].select { |message| message[:role] == "assistant" }.flat_map { |message| message[:content] }.pluck(:text)

      def notices = request.body[:messages].select { |message| message[:role] == "system" }.pluck(:content)

      it "gives the model its reply as it wrote it, tags included, and none of the lines its tags asked for" do
        words = "Isso o farmacêutico da loja responde."
        answered("posso tomar dipirona grávida?", at: Time.zone.local(2026, 11, 11, 15, 0),
                                                  body: FixedReply.with_notice(FixedReply.with_offer(words, "pt-BR"), "pt-BR"),
                                                  written: "[pt] #{words} [pharmacist]")
        current = turn_in(conversation, "e vocês entregam?", at: Time.zone.local(2026, 11, 11, 15, 2))

        runner.run(current)

        expect(request.body[:messages]).to eq([
          { role: "user", content: [ sent(0), { type: "text", text: "posso tomar dipirona grávida?" } ] },
          { role: "assistant", content: [ { type: "text", text: "[pt] Isso o farmacêutico da loja responde. [pharmacist]" } ] },
          { role: "user", content: [ sent(2), { type: "text", text: "e vocês entregam?" } ] }
        ])
      end

      it "says in one sentence of the system's what it sent in the model's place, never the text" do
        answered("tem dipirona?", at: Time.zone.local(2026, 11, 11, 15, 0), body: FixedReply.with_notice(FixedReply.fallback("pt-BR"), "pt-BR"),
                                  kind: "fallback")
        current = turn_in(conversation, "e agora?", at: Time.zone.local(2026, 11, 11, 15, 1))

        runner.run(current)

        expect(request.body[:messages]).to eq([
          { role: "user", content: [ sent(0), { type: "text", text: "tem dipirona?" }, sent(1), { type: "text", text: "e agora?" } ] },
          { role: "system", content: notice("fallback", 0) }
        ])
        expect(request.body[:messages].to_s).not_to include(FixedReply.fallback("pt-BR"))
      end

      it "has one sentence for each fixed text the system sends in the model's place, naming the visitor's message" do
        expect(AgentRunner::History::NOTICES.keys).to match_array(Turn::REPLY_KINDS - [ "model" ])
        expect(AgentRunner::History::NOTICES.values).to all(include("%<sent>s"))
      end

      # A system message must come before an assistant's or last: the notices
      # of turns the model did not answer wait for the next turn it did, and
      # join into one.
      it "keeps every notice after a user message and before an assistant's, joining those of the turns between" do
        answered("oi", at: Time.zone.local(2026, 11, 11, 15, 0), body: FixedReply.with_notice("Olá!", "pt-BR"), written: "[pt] Olá!")
        answered("posso tomar dipirona grávida?", at: Time.zone.local(2026, 11, 11, 15, 1),
                                                  body: FixedReply.with_offer(FixedReply.declined("pt-BR"), "pt-BR"), kind: "decline")
        answered("/ajuda", at: Time.zone.local(2026, 11, 11, 15, 2), body: FixedReply.help("pt-BR"), kind: "command")
        answered("tem?", at: Time.zone.local(2026, 11, 11, 15, 3), body: "Temos.", written: "[pt] Temos.")
        current = turn_in(conversation, "obrigado", at: Time.zone.local(2026, 11, 11, 15, 4))

        runner.run(current)

        messages = request.body[:messages]
        expect(messages.map { |message| message[:role] }).to eq(%w[user assistant user system assistant user])
        expect(messages[3][:content]).to eq("#{notice("decline", 1)}\n\n#{notice("command", 2)}")
        expect(messages.each_cons(2).select { |before, after| before[:role] == "system" || after[:role] == "system" })
          .to all(satisfy { |before, after| after[:role] != "system" || before[:role] == "user" })
      end

      # Review finding H-B2 of pull request #60 (cliente, the verifier's): a
      # conversation kept open by a visitor who writes every day outlives the
      # purge of its first reply, and the oldest reply left was read as the
      # first, its first paragraph dropped as the notice. The reply as the
      # model wrote it holds no notice to drop.
      it "gives the reply as the model wrote it, whatever reply the purge left first" do
        first = answered("oi", at: Time.zone.local(2026, 11, 11, 15, 0), body: FixedReply.with_notice("Olá!", "pt-BR"), written: "[pt] Olá!")
        answered("tem dipirona?", at: Time.zone.local(2026, 11, 11, 15, 1), body: FixedReply.with_offer("Temos.", "pt-BR"),
                                  written: "[pt] Temos. [pharmacist]")
        first.inbound_message.destroy!
        current = turn_in(conversation, "e entrega?", at: Time.zone.local(2026, 11, 11, 15, 2))

        runner.run(current)

        expect(written).to eq([ "[pt] Temos. [pharmacist]" ])
        expect(notices).to be_empty
      end

      # A reply stored before its turn kept what the model wrote (an image
      # before this slice, the old worker of Kamal's migration window, a
      # rollback) is read by its text.
      describe "a reply stored before its turn kept what the model wrote" do
        it "reads as the model's, as before, when it holds no line of the system's" do
          turn_in(conversation, "tem dipirona?", at: Time.zone.local(2026, 11, 11, 15, 0),
                                                 reply: FixedReply.with_notice("Temos.\n\nUma linha.", "pt-BR"))
          current = turn_in(conversation, "e paracetamol?", at: Time.zone.local(2026, 11, 11, 15, 1))

          runner.run(current)

          expect(written).to eq([ "Temos.\n\nUma linha." ])
          expect(notices).to be_empty
        end

        # Review finding C1 of pull request #60 (cliente, the verifier's): such
        # a reply came back whole as the model's, the offer's, the emergency's
        # or a reservation's line in it. Those lines, the ones a turn adds
        # after the model's words, are told by their text, in the three
        # languages, and left out, the tags that asked for them kept.
        it "gives back none of the lines a turn adds after the model's words, only the tags that asked for them" do
          offer = FixedReply.offer("en")
          line = FixedReply.reservations([ build(:reservation, code: "K7Q2XB", quantity: 1) ], "pt-BR")
          turn_in(conversation, "can I take dipyrone while pregnant?", at: Time.zone.local(2026, 11, 11, 15, 0),
                                                                      reply: FixedReply.with_notice("The store's pharmacist answers that.\n\n#{offer}", "en"))
          turn_in(conversation, "reserva uma", at: Time.zone.local(2026, 11, 11, 15, 1),
                                               reply: "Reservado.\n\n#{FixedReply.emergency("pt-BR")}\n\n#{line}")
          current = turn_in(conversation, "e vocês entregam?", at: Time.zone.local(2026, 11, 11, 15, 2))

          runner.run(current)

          expect(written).to eq([ "The store's pharmacist answers that. [pharmacist]", "Reservado. [emergency]" ])
          expect(notices).to be_empty
        end

        # Review finding R2 of pull request #60 (teorico, the verifier's): a
        # line in a reservation's form the model wrote is told as the
        # system's by its text alone; left out, it is never given back as the
        # system's either.
        it "never gives back a line in a reservation's form, the system's or one the model wrote" do
          turn_in(conversation, "oi", at: Time.zone.local(2026, 11, 11, 15, 0), reply: FixedReply.with_notice("Olá!", "pt-BR"))
          turn_in(conversation, "reserva uma dipirona", at: Time.zone.local(2026, 11, 11, 15, 1),
                                                        reply: "Pronto.\n\nReserva ZZ9Z9Z: 1 × Dipirona 500 mg, retirada até 12/11 às 18:00.")
          current = turn_in(conversation, "qual é minha reserva?", at: Time.zone.local(2026, 11, 11, 15, 2))

          runner.run(current)

          expect(request.body[:messages].to_s).not_to include("ZZ9Z9Z")
          expect(written).to eq([ "Olá!", "Pronto." ])
        end

        # Review finding R1 of pull request #60 (cliente, the verifier's): a
        # reply the check replaced before this slice is FR-09's decline, the
        # offer, then the products its search found, and the split by the
        # lines after the model's words stopped at the products, so the
        # decline and the offer came back as the model's. A reply the system
        # wrote in the model's place is told by the fixed text it opens with.
        it "gives a reply the system wrote in the model's place back as its notice, none of it as the model's" do
          products = FixedReply.products([ { "name" => "Dipirona 500 mg, 10 comprimidos", "price" => "R$ 7,90", "stock" => 12,
                                             "prescription_required" => false } ], "pt-BR")
          turn_in(conversation, "oi", at: Time.zone.local(2026, 11, 11, 15, 0), reply: FixedReply.with_notice("Olá!", "pt-BR"))
          turn_in(conversation, "posso tomar dipirona grávida?", at: Time.zone.local(2026, 11, 11, 15, 1),
                                                                reply: "#{FixedReply.with_offer(FixedReply.declined("pt-BR"), "pt-BR")}\n\n#{products}")
          turn_in(conversation, "y para un niño?", at: Time.zone.local(2026, 11, 11, 15, 2),
                                                   reply: FixedReply.with_emergency(FixedReply.declined("es"), "es"))
          turn_in(conversation, "hello?", at: Time.zone.local(2026, 11, 11, 15, 3), reply: FixedReply.fallback("en"))
          turn_in(conversation, "e aí?", at: Time.zone.local(2026, 11, 11, 15, 4), reply: FixedReply.paused("pt-BR"))
          current = turn_in(conversation, "e vocês entregam?", at: Time.zone.local(2026, 11, 11, 15, 5))

          runner.run(current)

          expect(written).to eq([ "Olá!" ])
          expect(notices).to eq([ [ notice("decline", 1), notice("refusal", 2), notice("fallback", 3), notice("pause", 4) ].join("\n\n") ])
          expect(request.body[:messages].to_s).not_to include("R$ 7,90")
        end
      end
    end

    # M2-11a (design §10, M2-4's note, the owner's word "Sim, junto na
    # M2-11a"): the history held no tool results, so the model saw its own
    # earlier claim of a reservation's code with nothing to back it, and the
    # economy model told a visitor, three times in six, that it could not
    # confirm a reservation it had made. An earlier turn's reservations come
    # back with their results, before the reply the model wrote.
    describe "what the tools did in earlier turns" do
      def step(id, name, input, result)
        [ { "role" => "assistant", "content" => [ { "type" => "tool_use", "id" => id, "name" => name, "input" => input } ] },
          { "role" => "user", "content" => [ { "type" => "tool_result", "tool_use_id" => id, "content" => result, "is_error" => false } ] } ]
      end

      let(:exchange) { step("toolu_01", "create_reservation", { "product_id" => "p1", "quantity" => 1 }, "{\"code\":\"K7Q2XB\"}") }

      def kept(turn, body:, **what)
        travel_to(Time.zone.local(2026, 11, 11, 15, 0, 5)) { Message.record_outbound!(turn:, body:) }
        turn.update!(tool_exchange: exchange, **what)
      end

      it "gives back an earlier turn's tool calls and their results, between its message and its reply" do
        kept(turn_in(conversation, "tem dipirona?", at: Time.zone.local(2026, 11, 11, 15, 0)), body: "Temos.", reply_kind: "model",
                                                                                                  model_reply: "[pt] Temos.")
        current = turn_in(conversation, "reserva uma", at: Time.zone.local(2026, 11, 11, 15, 1))

        runner.run(current)

        expect(request.body[:messages]).to eq([
          { role: "user", content: [ { type: "text", text: "Sent Wednesday, 2026-11-11 15:00 (São Paulo time)" }, { type: "text", text: "tem dipirona?" } ] },
          { role: "assistant", content: [ { type: "tool_use", id: "toolu_01", name: "create_reservation", input: { product_id: "p1", quantity: 1 } } ] },
          { role: "user", content: [ { type: "tool_result", tool_use_id: "toolu_01", content: "{\"code\":\"K7Q2XB\"}", is_error: false } ] },
          { role: "assistant", content: [ { type: "text", text: "[pt] Temos." } ] },
          { role: "user", content: [ { type: "text", text: "Sent Wednesday, 2026-11-11 15:01 (São Paulo time)" }, { type: "text", text: "reserva uma" } ] }
        ])
      end

      it "keeps the results first in their user message, and the notice of a text in the model's place after the visitor's next one" do
        kept(turn_in(conversation, "tem dipirona?", at: Time.zone.local(2026, 11, 11, 15, 0)), body: FixedReply.fallback("pt-BR"),
                                                                                                  reply_kind: "fallback")
        current = turn_in(conversation, "e agora?", at: Time.zone.local(2026, 11, 11, 15, 1))

        runner.run(current)

        messages = request.body[:messages]
        expect(messages.map { |message| message[:role] }).to eq(%w[user assistant user system])
        expect(messages[2][:content].map { |block| block[:type] }).to eq(%w[tool_result text text])
        expect(messages.last[:content]).to eq(format(AgentRunner::History::NOTICES.fetch("fallback"),
                                                     sent: "Wednesday, 2026-11-11 15:00 (São Paulo time)"))
      end

      # Review finding V2 of pull request #60 (cannot tell, the verifier's;
      # the slice's probe made it red): a lookup's result is what was true
      # when it ran, and the economy model told a visitor a product it had
      # found was still in stock, three times in three, after the stock ran
      # out, where on main it searched again. The history gives back what
      # the model did, never what it looked up, which it looks up again.
      it "gives back no lookup of an earlier turn, a search or a store fact, only what the model did" do
        search = step("toolu_02", "search_products", { "query" => "loratadina" }, "{\"products\":[{\"stock\":18}]}")
        info = step("toolu_03", "get_store_info", { "topic" => "hours" }, "{\"hours\":\"08:00\"}")
        both = [ { "role" => "assistant", "content" => search.first["content"] + exchange.first["content"] },
                 { "role" => "user", "content" => search.last["content"] + exchange.last["content"] } ]
        kept(turn_in(conversation, "tem loratadina? reserva uma", at: Time.zone.local(2026, 11, 11, 15, 0)),
             body: "Reservei.", reply_kind: "model", model_reply: "[pt] Reservei.")
        Turn.last.update!(tool_exchange: search + info + both)
        current = turn_in(conversation, "ainda tem?", at: Time.zone.local(2026, 11, 11, 15, 1))

        runner.run(current)

        messages = request.body[:messages]
        expect(messages.to_s).not_to include("toolu_02", "toolu_03", "search_products", "get_store_info", "stock")
        expect(messages[1..2]).to eq([
          { role: "assistant", content: [ { type: "tool_use", id: "toolu_01", name: "create_reservation", input: { product_id: "p1", quantity: 1 } } ] },
          { role: "user", content: [ { type: "tool_result", tool_use_id: "toolu_01", content: "{\"code\":\"K7Q2XB\"}", is_error: false } ] }
        ])
      end

      it "keeps out the calls of the turn it runs, which the SDK's runner sends itself" do
        turn.update!(tool_exchange: exchange)

        runner.run(turn)

        expect(request.body[:messages].to_s).not_to include("toolu_01")
      end
    end
  end

  describe "the reply (FR-02)" do
    it "returns the reply without its language tag, and the language the tag names" do
      result = runner.run(turn)

      expect(result).to have_attributes(outcome: :replied, text: "Temos, sim.", language: "pt-BR")
    end

    # M2-11a (the owner, 2026-11-20: "(d) Só o que o modelo escreveu"): the
    # later turns' history gives the model back this, its tags in the places
    # the prompt asks for them, as the system read them (History).
    it "returns the reply as the model wrote it: its language's tag first, its words, then the tags of the lines it asked for" do
      responses.replace([ reply("[pharmacist] [PT-br] Temos dipirona.\n\nQuer reservar? [emergency] [pharmacist]") ])

      expect(runner.run(turn).written).to eq("[pt] Temos dipirona.\n\nQuer reservar? [pharmacist] [emergency]")
    end

    it "returns a reply with no words, or no language's tag, as the tags the model wrote" do
      responses.replace([ reply("[pt] [pharmacist]"), reply("Temos. [emergency]") ])

      expect(runner.run(turn).written).to eq("[pt] [pharmacist]")
      expect(runner.run(turn).written).to eq("Temos. [emergency]")
    end

    it "returns no reply as written for a turn the model did not answer" do
      responses.replace([ refusal ])

      expect(runner.run(turn)).to have_attributes(outcome: :refused, written: nil)
    end

    context "when the reply is in Spanish" do
      let(:responses) { [ reply("[es] ¡Sí, hacemos entregas!") ] }

      it "names Spanish" do
        expect(runner.run(turn)).to have_attributes(text: "¡Sí, hacemos entregas!", language: "es")
      end
    end

    # A tag the prompt did not spell exactly reached the visitor and named no
    # language (a dismissal of pull request #9's review and finding C4 of
    # #27, fixed by the MVP review's lot, 2026-11-15).
    {
      "[PT] Temos, sim." => "pt-BR", "[pt-BR] Temos, sim." => "pt-BR", "[Pt-br] Temos, sim." => "pt-BR",
      "[pt_BR] Temos, sim." => "pt-BR", "[EN-US] Temos, sim." => "en", "[es-419] Temos, sim." => "es", "[ES] Temos, sim." => "es"
    }.each do |written, language|
      context "when the tag is written #{written[/\[[^\]]+\]/]}" do
        let(:responses) { [ reply(written) ] }

        it "reads it as #{language} and shows it not" do
          expect(runner.run(turn)).to have_attributes(outcome: :replied, text: "Temos, sim.", language:)
        end
      end
    end

    context "when a line tag comes before the language tag" do
      let(:responses) { [ reply("[pharmacist] [pt] Isso eu não posso responder.") ] }

      it "takes the line tag out first, then reads the language tag" do
        expect(runner.run(turn)).to have_attributes(text: "Isso eu não posso responder.", language: "pt-BR", offer: true)
      end
    end

    context "when a line tag stands on its own line before the language tag" do
      let(:responses) { [ reply("[emergency]\n[en] Call the emergency services now.") ] }

      it "reads the language all the same" do
        expect(runner.run(turn)).to have_attributes(text: "Call the emergency services now.", language: "en", emergency: true)
      end
    end

    context "when a bracketed word is no language tag" do
      let(:responses) { [ reply("[fr] Bonjour.") ] }

      it "leaves it in the text and names no language" do
        expect(runner.run(turn)).to have_attributes(text: "[fr] Bonjour.", language: nil)
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

      # The close of M2-11a2's XC-1 (the owner, 2026-11-20, M2-11a3): the
      # model's notes to itself before a tool call reached visitors, so the
      # result names what was written before a call, as the visitor reads
      # it, for the evals to fail; the reply keeps it all the same.
      it "names the words written before a tool call, as the visitor reads them" do
        expect(runner.run(turn).before_tools).to eq([ "Déjame ver." ])
      end
    end

    context "when the model writes only after its tool calls" do
      let(:responses) { [ tool_turn(tool_use("echo", { "text" => "x" })), reply("[es] Sí, hacemos entregas.") ] }

      it "names no words before a tool call" do
        expect(runner.run(turn)).to have_attributes(text: "Sí, hacemos entregas.", before_tools: [])
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

    # Review finding V1 of #60's first verifier (the owner, 2026-11-20,
    # M2-11a3): a reply of spaces String#strip leaves, a no-break space among
    # them, came back as text; the stored body refused it as blank, so the
    # visitor got the fallback only after the job's three attempts.
    # The review of #62 (H4, teorico, a regression of the line above's fix):
    # NUL is not a space to [[:space:]], though String#strip took it, so a
    # reply of NULs alone came back as text the stored body then deletes.
    context "when the reply's words are only NUL characters" do
      let(:responses) { [ reply("[pt]\u0000\u0000") ] }

      it "ends as an empty reply does, for the fallback at once (NFR-03)" do
        expect(runner.run(turn)).to have_attributes(outcome: :incomplete, text: nil)
      end
    end

    context "when the reply's words are only spaces strip leaves" do
      let(:responses) { [ reply("[pt] #{"\u00a0"} #{"\u00a0"}\n\t"), reply("#{"\u00a0"}") ] }

      it "ends as an empty reply does, for the fallback at once (NFR-03)" do
        expect(runner.run(turn)).to have_attributes(outcome: :incomplete, text: nil, offer: false)
        expect(runner.run(turn)).to have_attributes(outcome: :incomplete, text: nil)
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
      expect(events.first).to have_attributes(model: "claude-opus-5-5", effort: "low")
    end

    it "measures each model call" do
      result = runner.run(turn)

      expect(result.model_calls).to all(have_attributes(model: "claude-opus-5-5", latency_ms: a_value >= 0, error: nil))
      expect(result.model_calls.map(&:stop_reason)).to eq(%w[tool_use end_turn])
    end

    # M2-11a: what the history of the next turns gives back (History).
    it "returns the turn's tool calls and their results, step by step, as the model read them, without thinking or text" do
      responses.replace([ tool_turn(tool_use("echo", { "text" => "dipirona" }, id: "toolu_01")), reply("[pt] Temos dipirona.") ])

      result = runner.run(turn)

      expect(result.exchange).to eq([
        { "role" => "assistant", "content" => [ { "type" => "tool_use", "id" => "toolu_01", "name" => "echo", "input" => { "text" => "dipirona" } } ] },
        { "role" => "user", "content" => [ { "type" => "tool_result", "tool_use_id" => "toolu_01",
                                             "content" => JSON.generate("echo" => "dipirona", "turn_id" => turn.id), "is_error" => false } ] }
      ])
    end

    it "returns no step for a turn that called no tool" do
      responses.replace([ reply("[pt] Olá!") ])

      expect(runner.run(turn).exchange).to eq([])
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

      # The seventh call's result is the gate's refusal, which the model read.
      it "returns both steps, the seventh call with the refusal it got" do
        results = runner.run(turn).exchange.select { |message| message["role"] == "user" }.flat_map { |message| message["content"] }

        expect(results.size).to eq(7)
        expect(results.last).to include("is_error" => true, "content" => a_string_including("limit of 6 tool calls"))
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

    # SR-20's exception closed (M3-4; review finding C2's sister of pull
    # request #9): the SDK gave a retry the timeout its call began with, so a
    # retry that started before the sixty seconds could run near sixty more.
    describe "the turn's hard edge" do
      let(:delays) { [] }
      let(:sleeper) { ->(seconds) { delays << seconds && clock.advance(seconds) } }

      context "when a step's call is retried after a wait" do
        let(:responses) { [ slow_turn, error(:overloaded).merge(headers: { "retry-after" => "2" }), reply("[pt] pronto") ] }

        it "gives the retry only what is left once the wait is over" do
          result = AgentRunner.new(client: fake.client, tools: [ slow_echo(25) ], clock:, sleeper:).run(turn)

          expect(result).to have_attributes(outcome: :replied, text: "pronto")
          expect(fake.requests.map { |sent| sent.options[:timeout] }).to eq([ 60, 35, 33 ])
          expect(delays).to eq([ 2.0 ])
        end
      end

      # A client middleware above the fake moves the clock by the attempt's
      # whole timeout, as an attempt that waits until the edge does.
      def waiting_client(fake)
        FakeModel::Client.new(fake, api_key: "fake-model", max_retries: AgentRunner::MAX_RETRIES, initial_retry_delay: 0,
                                    middleware: [ ->(request, nxt) { clock.advance(request.timeout) && nxt.call(request) } ])
      end

      context "when an attempt waits until the edge" do
        let(:responses) { [ { timeout: true }, reply("[pt] tarde demais") ] }

        it "is not tried again, and the turn ends at its deadline" do
          result = AgentRunner.new(client: waiting_client(fake), tools: [ SpecTools::Echo ], clock:, sleeper:).run(turn)

          expect(result).to have_attributes(outcome: :deadline, text: nil)
          expect(fake.requests.size).to eq(1)
        end

        # The provider runs an abandoned call to its end and bills it whole
        # (design §10, question 20; the owner, 2026-11-15): its input counted
        # high from the request's characters, and its output cap.
        it "charges the abandoned attempt at its input and its output cap (FR-14)" do
          events = []
          result = AgentRunner.new(client: waiting_client(fake), tools: [ SpecTools::Echo ], clock:, sleeper:)
                              .run(turn) { |event| events << event }

          input = (JSON.generate(fake.requests.first.body).length / AgentRunner::CHARACTERS_PER_TOKEN).ceil
          charged = AgentRunner::Usage.new(model: "claude-opus-5-5", input_tokens: input, output_tokens: 1500,
                                           cache_creation_tokens: 0, cached_tokens: 0)
          expect(result.model_calls).to contain_exactly(have_attributes(error: "Anthropic::Errors::APITimeoutError", usage: [ charged ]))
          expect(events.grep(AgentRunner::ModelCall).flat_map(&:usage)).to eq([ charged ])
        end
      end

      # Review finding F8 of pull request #65: a request whose JSON could not
      # be written was counted from its text with no line saying so.
      it "says so in a line, by the error's class, when it counts an abandoned request from its text" do
        allow(JSON).to receive(:generate).and_wrap_original do |original, object, *rest|
          raise JSON::GeneratorError, "#{object}" if object.is_a?(Hash) && object.key?(:max_tokens)

          original.call(object, *rest)
        end
        allow(Rails.logger).to receive(:warn).and_call_original
        fake = FakeModel.new([ { timeout: true } ])

        result = AgentRunner.new(client: waiting_client(fake), tools: [ SpecTools::Echo ], clock:, sleeper:).run(turn)

        expect(result.model_calls.sole.usage.sole.output_tokens).to eq(1500)
        expect(Rails.logger).to have_received(:warn).with("agent: an abandoned attempt's request counted from its text, its JSON failed: JSON::GeneratorError")
      end

      # A connection that never opened sent nothing, so nothing is billed: a
      # network down for the host would otherwise charge a whole call for
      # every turn it met.
      context "when the attempt's connection never opened" do
        let(:responses) { [ { timeout: "open" } ] }

        it "charges nothing for it" do
          result = AgentRunner.new(client: waiting_client(fake), tools: [ SpecTools::Echo ], clock:, sleeper:).run(turn)

          expect(result).to have_attributes(outcome: :deadline)
          expect(result.model_calls).to contain_exactly(have_attributes(usage: []))
        end
      end

      context "when an attempt timed out before a retry that answered" do
        let(:responses) { [ { timeout: true }, reply("[pt] pronto", usage: usage(input: 900, output: 60, cache_read: 0)) ] }

        it "charges the abandoned attempt beside the answer's usage" do
          client = FakeModel::Client.new(fake, api_key: "fake-model", max_retries: AgentRunner::MAX_RETRIES, initial_retry_delay: 0,
                                               middleware: [ ->(request, nxt) { clock.advance(5) && nxt.call(request) } ])
          result = AgentRunner.new(client:, tools: [ SpecTools::Echo ], clock:, sleeper:).run(turn)

          expect(result).to have_attributes(outcome: :replied, text: "pronto")
          expect(result.model_calls.sole.usage.map { |usage| [ usage.input_tokens.positive?, usage.output_tokens ] })
            .to eq([ [ true, 60 ], [ true, 1500 ] ])
          expect(fake.requests.map { |sent| sent.options[:timeout] }).to eq([ 60, 55 ])
        end
      end

      context "when a tool call would start after the edge" do
        let(:responses) { [ tool_turn(tool_use("slow_echo", { "text" => "x" }), tool_use("echo", { "text" => "y" })), reply("[pt] tarde") ] }

        it "is refused, and the turn ends at its deadline" do
          result = AgentRunner.new(client: fake.client, tools: [ slow_echo(61), SpecTools::Echo ], clock:, sleeper:).run(turn)

          expect(result).to have_attributes(outcome: :deadline, text: nil)
          expect(result.tool_calls.map(&:name)).to eq([ "slow_echo" ])
          expect(fake.requests.size).to eq(1)
        end
      end

      # Review finding F2 of pull request #65: an attempt was made with any
      # time left, however little, and one that could never answer was
      # still billed. A model call starts only with MIN_ATTEMPT left, and a
      # retry only when its wait leaves that much.
      context "when less is left of the edge than an attempt needs" do
        let(:responses) { [ reply("[pt] tarde") ] }

        it "makes no attempt, and the turn ends at its deadline" do
          clock.advance(60 - 0.7)
          result = AgentRunner.new(client: fake.client, tools: [ SpecTools::Echo ], clock:, sleeper:)
                              .run(turn, edge: TurnEdge.new(deadline: 60, clock:))

          expect(result).to have_attributes(outcome: :deadline, text: nil)
          expect(fake.requests).to be_empty
        end
      end

      context "when a retry's wait would leave less than an attempt needs" do
        let(:responses) { [ slow_turn, error(:rate_limit).merge(headers: { "retry-after" => "33" }), reply("[pt] tarde") ] }

        it "is not waited for, and the turn ends with the API's error" do
          result = AgentRunner.new(client: fake.client, tools: [ slow_echo(25) ], clock:, sleeper:).run(turn)

          expect(result).to have_attributes(outcome: :model_error, text: nil, error: an_instance_of(Anthropic::Errors::RateLimitError))
          expect(delays).to be_empty
          expect(fake.requests.size).to eq(2)
        end
      end

      # Review findings C5 and F7 of pull request #65: an error was read as
      # the edge's once the clock had passed it, so a refused key or request
      # landing at the edge read as the turn's time spent, which FR-17's
      # canary never counts as the route's fault. The error decides, not the
      # clock: the API's refusal is a model error wherever it lands.
      context "when the API refuses the request as the edge passes" do
        let(:responses) { [ { status: 401, body: { type: "error", error: { type: "authentication_error", message: "invalid x-api-key" } } } ] }

        it "ends the turn as a model error, with the API's error" do
          client = FakeModel::Client.new(fake, api_key: "fake-model", max_retries: 0, initial_retry_delay: 0,
                                               middleware: [ ->(request, nxt) { clock.advance(request.timeout) && nxt.call(request) } ])
          result = AgentRunner.new(client:, tools: [ SpecTools::Echo ], clock:, sleeper:).run(turn)

          expect(result).to have_attributes(outcome: :model_error, error: an_instance_of(Anthropic::Errors::AuthenticationError))
        end
      end

      # The caller's edge, FR-17's canary's twenty seconds among them
      # (TurnProcessor), bounds the model's steps as the sixty seconds do.
      context "when the caller gives the turn an edge of its own" do
        let(:responses) { [ reply("[pt] pronto") ] }

        it "gives the request only what is left of that edge" do
          clock.advance(3)
          AgentRunner.new(client: fake.client, tools: [ SpecTools::Echo ], clock:, sleeper:)
                     .run(turn, edge: TurnEdge.new(deadline: 20, clock:))

          expect(fake.requests.sole.options[:timeout]).to eq(17)
        end
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
      let(:sleeper) { ->(seconds) { delays << seconds && clock.advance(seconds) } }
      let(:runner) { AgentRunner.new(client: fake.client, tools: [ SpecTools::Echo ], clock:, sleeper:) }

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

      # A reservation made before the error is a fact the next turn's model
      # reads back (M2-11a).
      it "keeps the step made before it in the exchange" do
        expect(runner.run(turn).exchange.map { |message| message["role"] }).to eq(%w[assistant user])
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
