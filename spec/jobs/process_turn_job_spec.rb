require "rails_helper"

RSpec.describe "design §6.3 ProcessTurnJob, one turn from its inbound message to its reply (FR-01, FR-02, FR-12, NFR-02, NFR-03)" do
  include ModelResponses
  # A retry is enqueued on the test adapter, never run by a thread of its own.
  include ActiveJob::TestHelper

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

  # FR-10's MVP note: where the model's tag asks for it (AgentRunner), the
  # reply ends with the offer's fixed line, in the reply's language, before
  # the line of any reservation the turn stored (FR-07).
  describe "the offer of the pharmacist (FR-09, FR-10's MVP note)" do
    it "ends the reply with the offer, in the language the reply names" do
      responses.replace([ reply("[es] Eso no lo puedo responder por aquí; lo responde el farmacéutico de la tienda. [pharmacist]") ])
      turn = inbound("¿puedo tomar paracetamol estando embarazada?")

      perform(turn)

      text = FixedReply.with_offer("Eso no lo puedo responder por aquí; lo responde el farmacéutico de la tienda.", "es")
      expect(turn.outbound_message.body).to eq(FixedReply.with_notice(text, "es"))
    end

    it "keeps the reply as the model wrote it when the tag is not there" do
      responses.replace([ reply("[pt] Olá!"), reply("[pt] Precisa de receita, sim; ela é apresentada no balcão.") ])
      perform(inbound("oi"))
      turn = inbound("preciso de receita pra amoxicilina?")

      perform(turn)

      expect(turn.outbound_message.body).to eq("Precisa de receita, sim; ela é apresentada no balcão.")
    end

    it "puts the offer before the line of a reservation the reply left out" do
      product = create(:product, stock: 10)
      responses.replace([ tool_turn(tool_use("create_reservation", { product_id: product.id, quantity: 2 })),
                          reply("[pt] Reservei. A dose quem indica é o farmacêutico. [pharmacist]") ])
      turn = inbound("reserva duas dipironas e me diz a dose")

      perform(turn)

      line = FixedReply.reservations(turn.reservations.to_a, "pt-BR")
      expect(turn.outbound_message.body)
        .to end_with("Reservei. A dose quem indica é o farmacêutico.\n\n#{FixedReply.offer("pt-BR")}\n\n#{line}")
    end

    # The owner's decision of 2026-11-14: a person at the counter gives the
    # phone once, so the line is left out when the conversation's last reply
    # carried it, and comes back after a reply that did not.
    describe "a line the last reply carried" do
      before do
        responses.replace([ reply("[pt] Isso eu não posso responder. [pharmacist]"), reply("[pt] Também não posso. [pharmacist]"),
                            reply("[pt] Temos dipirona."), reply("[pt] Isso também não. [pharmacist]") ])
      end

      it "is not repeated in the next reply, and comes back after one without it" do
        turns = [ "posso tomar com cerveja?", "e com vinho?", "tem dipirona?", "e pra criança?" ].map do |text|
          inbound(text).tap { |turn| perform(turn) }
        end

        expect(turns.map { |turn| turn.outbound_message.body.end_with?(FixedReply.offer("pt-BR")) }).to eq([ true, false, false, true ])
        expect(turns.second.outbound_message.body).to eq("Também não posso.")
      end

      it "is not repeated after a refusal's decline that carried it" do
        responses.replace([ refusal, reply("[pt] Também não posso. [pharmacist]") ])
        first = inbound("como faço para ...").tap { |turn| perform(turn) }
        second = inbound("e com vinho?").tap { |turn| perform(turn) }

        expect(first.outbound_message.body).to end_with(FixedReply.offer("pt-BR"))
        expect(second.outbound_message.body).to eq("Também não posso.")
      end

      # Review finding C1 of pull request #27: a reply that is the tag alone
      # has nothing else to say, so the line is its text, last reply or not.
      it "is the reply when the model wrote the tag alone, even after a reply that carried it" do
        responses.replace([ reply("[pt] Isso eu não posso responder. [pharmacist]"), reply("[pt] [pharmacist]") ])
        perform(inbound("posso tomar com cerveja?"))
        turn = inbound("Quero falar com o farmacêutico.").tap { |later| perform(later) }

        expect(turn.reload.state).to eq("replied")
        expect(turn.outbound_message.body).to eq(FixedReply.offer("pt-BR"))
      end

      it "comes back when the reply is in another language than the last one's line" do
        responses.replace([ reply("[pt] Isso eu não posso responder. [pharmacist]"), reply("[en] I can't answer that either. [pharmacist]") ])
        perform(inbound("posso tomar com cerveja?"))
        turn = inbound("can I take it with wine?").tap { |later| perform(later) }

        expect(turn.outbound_message.body).to eq(FixedReply.with_offer("I can't answer that either.", "en"))
      end
    end
  end

  # FR-09, the owner's decision of 2026-11-14: a message that may be an
  # emergency ends with the emergency line, alone, since its one instruction
  # is to call for help; the line comes every time, unlike the offer.
  describe "the emergency line (FR-09)" do
    it "ends the reply with the emergency line in the reply's language, and leaves the offer out" do
      responses.replace([ reply("[pt] Ligue agora para o socorro. [emergency] [pharmacist]") ])
      turn = inbound("meu filho engoliu uns comprimidos")

      perform(turn)

      expect(turn.outbound_message.body).to eq(FixedReply.with_notice(FixedReply.with_emergency("Ligue agora para o socorro.", "pt-BR"), "pt-BR"))
    end

    # Review finding C1 of pull request #27: a reply that is the tag alone
    # was empty, so the visitor got the fallback and no emergency numbers.
    it "is the reply when the model wrote the tag alone, and the turn is replied" do
      responses.replace([ reply("[pt] [emergency]") ])
      turn = inbound("meu filho engoliu uns comprimidos")

      perform(turn)

      expect(turn.reload.state).to eq("replied")
      expect(turn.outbound_message.body).to eq(FixedReply.with_notice(FixedReply.emergency("pt-BR"), "pt-BR"))
    end

    it "comes in every reply that asks for it" do
      responses.replace([ reply("[pt] Ligue agora para o socorro. [emergency]"), reply("[pt] Ligue agora, por favor. [emergency]") ])
      perform(inbound("meu filho engoliu uns comprimidos"))
      turn = inbound("e agora?").tap { |later| perform(later) }

      expect(turn.outbound_message.body).to eq(FixedReply.with_emergency("Ligue agora, por favor.", "pt-BR"))
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

    # The page stamps the notice apart from the reply, without matching its
    # text (design §10, note of 2026-11-12); the stored body is what any
    # channel sends, notice included (FR-01).
    it "sends the notice apart from the reply's body to the conversation's stream" do
      responses.replace([ reply("[es] ¡Hola! ¿Buscas algún producto?") ])
      turn = inbound("hola")

      expect { perform(turn) }.to have_broadcasted_to("conversation:#{conversation.id}")
        .with(type: "message", message: a_hash_including(notice: FixedReply.notice("es"), body: "¡Hola! ¿Buscas algún producto?"))
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

    # FR-07's first scenario, through the job: the model reserves, the stock
    # goes down and the reply carries the code; the turn run again answers
    # from the stored reservation, never through the model (NFR-02).
    it "reserves through the model, and a run of the same turn again neither reserves nor calls the model again" do
      product = create(:product, stock: 10)
      responses.replace([ tool_turn(tool_use("create_reservation", { product_id: product.id, quantity: 2 })),
                          reply("[pt] Reservado, o código está abaixo.") ])
      turn = inbound("reserva duas dipironas")

      perform(turn)
      reservation = turn.reservations.sole
      # Review finding V3 of pull request #19: the reply said the code was
      # below, and nothing followed.
      expect(turn.outbound_message.body).to end_with(FixedReply.reservations([ reservation ], "pt-BR"))
      Message.where(turn_id: turn.id).delete_all
      perform(turn)

      expect(fake.requests.size).to eq(2)
      expect(product.reload.stock).to eq(8)
      expect(turn.reservations.sole).to eq(reservation)
      expect(turn.reload.outbound_message.body).to eq(FixedReply.with_notice(FixedReply.reservations([ reservation ], "pt-BR"), "pt-BR"))
    end

    # FR-07: "the reply carries a reservation code and the pickup deadline",
    # whatever the model wrote (review finding C1 of pull request #19): a
    # reply that leaves out a reservation's code or its pickup time is
    # followed by the reservation's line.
    describe "the reservation's code and deadline in the reply" do
      let(:product) { create(:product, stock: 10) }

      # A Thursday at noon in São Paulo: the pickup is Friday at 20:00.
      def reserve_and_reply(text)
        allow(Reservation).to receive(:generate_code).and_return("4K2QHM")
        responses.replace([ tool_turn(tool_use("create_reservation", { product_id: product.id, quantity: 2 })),
                            reply("[pt] #{text}") ])
        turn = inbound("reserva duas caixas", at: Time.zone.local(2026, 11, 12, 12, 4))
        travel_to(Time.zone.local(2026, 11, 12, 12, 4, 3)) { perform(turn) }
        turn
      end

      it "follows a reply that leaves out the code and the deadline with the reservation's line" do
        turn = reserve_and_reply("Pronto, sua reserva de duas caixas está feita, pode retirar amanhã.")

        reservation = turn.reservations.sole
        expect(turn.outbound_message.body)
          .to end_with("Pronto, sua reserva de duas caixas está feita, pode retirar amanhã.\n\n" \
                       "#{FixedReply.reservations([ reservation ], "pt-BR")}")
      end

      it "follows a reply that writes the code but not the pickup time with the line" do
        turn = reserve_and_reply("Reservado! O código é 4K2QHM.")

        expect(turn.outbound_message.body).to end_with(FixedReply.reservations(turn.reservations.to_a, "pt-BR"))
      end

      it "adds nothing to a reply that writes the code and the pickup day and time" do
        turn = reserve_and_reply("Reservado! O código é 4K2QHM, e a retirada é até sexta, 13/11, às 20:00.")

        expect(turn.outbound_message.body).to end_with("Reservado! O código é 4K2QHM, e a retirada é até sexta, 13/11, às 20:00.")
      end

      # Review finding R1 of pull request #19: every weekday closes at 20:00,
      # so the time alone was any "20:00" in the reply, with no day or the
      # wrong one.
      [
        "Reservado! O código é 4K2QHM. Funcionamos das 08:00 às 20:00.",
        "Reservado! O código é 4K2QHM, retire até as 20:00.",
        "Reservado! O código é 4K2QHM, retire até segunda, 16/11, às 20:00."
      ].each do |text|
        it "follows a reply that writes the code and 20:00 but not the pickup day with the line: #{text}" do
          turn = reserve_and_reply(text)

          expect(turn.outbound_message.body).to end_with("#{text}\n\n#{FixedReply.reservations(turn.reservations.to_a, "pt-BR")}")
        end
      end
    end

    # FR-07: "the attendant refuses and lists the open ones". The system lists
    # them under the reply, whatever the model wrote, and the refusal the
    # trace keeps carries none of them, since they may be another
    # conversation's (review findings C5 and N1 of pull request #19; FR-12).
    describe "the fourth reservation, refused at the cap" do
      let(:earlier) { create(:conversation, visitor:, closed_at: 1.hour.ago) }
      # Due at 20:00, as every weekday closes (config/store.yml).
      let!(:held) do
        Array.new(3) do
          create(:reservation, visitor:, product: create(:product), pickup_until: 1.day.from_now.change(hour: 20),
                               turn: create(:turn, inbound_message: create(:message, conversation: earlier)))
        end
      end

      def ask_for_a_fourth
        responses.replace([ tool_turn(tool_use("create_reservation", { product_id: create(:product).id, quantity: 1 })),
                            reply("[pt] Você já tem o máximo de reservas abertas.") ])
        turn = inbound("reserva mais uma caixa")
        perform(turn)
        turn
      end

      it "lists the ones the reply names without their pickup day, on the same terms (review finding R1 of #19)" do
        responses.replace([ tool_turn(tool_use("create_reservation", { product_id: create(:product).id, quantity: 1 })),
                            reply("[pt] Você já tem a #{held.first.code}, que sai às 20:00, e mais duas.") ])
        turn = inbound("reserva mais uma caixa")
        perform(turn)

        expect(turn.outbound_message.body).to end_with(FixedReply.reservations(held, "pt-BR"))
      end

      it "lists under the reply the three the visitor holds" do
        turn = ask_for_a_fourth

        expect(turn.outbound_message.body)
          .to end_with("Você já tem o máximo de reservas abertas.\n\n#{FixedReply.reservations(held, "pt-BR")}")
        expect(turn.reservations).to be_empty
      end

      it "sends the reply with the codes it lists, for the chat to stamp" do
        expect { ask_for_a_fourth }
          .to have_broadcasted_to("conversation:#{conversation.id}")
          .with(hash_including(type: "message", message: hash_including(codes: match_array(held.map(&:code)))))
      end

      it "keeps the reservations of another conversation out of this one's trace" do
        turn = ask_for_a_fourth

        tool = spans(turn).find_by(name: "anthropic.custom_tool_use create_reservation")
        expect(tool.span_attributes).to include("balcao.tool_result.refusal" => "open_limit")
        held.each { |reservation| expect(tool.span_attributes.to_json).not_to include(reservation.code) }
      end
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

    # NFR-03's scenario: the three attempts are the SDK's, inside the turn; the
    # turn ends with its fallback, so the job has nothing to try again.
    it "is not tried a fourth time by the job after the model's three 529s" do
      responses.replace(Array.new(3) { error(:overloaded) })
      turn = inbound("oi")

      perform(turn)

      expect(fake.requests.size).to eq(3)
      expect(enqueued_jobs).to be_empty
    end

    it "carries the line of a reservation stored before the error" do
      product = create(:product)
      responses.replace([ tool_turn(tool_use("create_reservation", { product_id: product.id, quantity: 2 })),
                          *Array.new(3) { error(:overloaded) } ])
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
      # FR-09: the decline ends with the offer of the pharmacist (FR-10's MVP note).
      expect(turn.outbound_message.body).to eq(FixedReply.with_notice(FixedReply.with_offer(FixedReply.declined("pt-BR"), "pt-BR"), "pt-BR"))
      expect(spans(turn).first.span_attributes).to include("balcao.turn.outcome" => "refused")
    end

    it "marks the turn failed, closes its spans and tries again later when the turn breaks outside the model" do
      turn = inbound("oi")
      allow(Message).to receive(:record_outbound!).and_raise(ActiveRecord::ConnectionFailed, "gone")

      before = Time.current.to_f
      perform(turn)
      after = Time.current.to_f

      retry_job = enqueued_jobs.sole
      expect(retry_job).to include(job: ProcessTurnJob, args: [ turn.id ])
      expect(retry_job[:at]).to be_between(before + 3, after + 3.15)
      expect(turn.reload.state).to eq("failed")
      expect(spans(turn).where(finished_at: nil)).to be_empty
      expect(spans(turn).first.span_attributes).to include("error.type" => "ActiveRecord::ConnectionFailed")
    end
  end

  describe "the job's attempts and its dead letter (NFR-03)" do
    # Runs the job and every retry it enqueues, each at once, and answers the
    # waits it asked for; the last attempt's error, if any, comes out.
    def run_to_the_end(turn)
      waits = []
      record = ->(event) { waits << event.payload[:wait] }
      ActiveSupport::Notifications.subscribed(record, "enqueue_retry.active_job") do
        ProcessTurnJob.perform_later(turn.id)
        perform_enqueued_jobs until enqueued_jobs.empty?
      end
      waits
    end

    def roots(turn) = spans(turn).where(name: "balcao.turn").reorder(:created_at, :id)

    it "answers on a later attempt when the break clears, waiting longer before each" do
      responses.replace(Array.new(3) { reply("[pt] Olá!") })
      turn = inbound("oi")
      calls = 0
      original = Message.method(:record_outbound!)
      allow(Message).to receive(:record_outbound!) do |**arguments|
        calls += 1
        raise ActiveRecord::ConnectionFailed, "gone" if calls < 3

        original.call(**arguments)
      end

      waits = run_to_the_end(turn)

      expect(turn.reload).to have_attributes(state: "replied", outbound_message: be_present)
      expect(waits.size).to eq(2)
      expect(waits.first).to be_between(3, 3.15)
      expect(waits.last).to be_between(18, 20.4)
      expect(roots(turn).map { |root| root.span_attributes["balcao.turn.outcome"] }).to eq([ nil, nil, "replied" ])
    end

    it "gives up after the third attempt: the visitor gets the fallback, the trace says why, and the job fails for the queue's dead letter" do
      allow(Rails.logger).to receive(:error)
      conversation.update!(language: "en")
      turn = inbound("hello")
      allow(AgentRunner).to receive(:new).and_raise(RuntimeError, "a bug in the runner")
      broadcasts = []
      allow(ActionCable.server).to receive(:broadcast) { |stream, payload| broadcasts << [ stream, payload ] }

      expect { run_to_the_end(turn) }.to raise_error(RuntimeError, "a bug in the runner")

      expect(enqueued_jobs).to be_empty
      expect(turn.reload.state).to eq("failed")
      expect(turn.outbound_message.body).to eq(FixedReply.with_notice(FixedReply.fallback("en"), "en"))
      expect(broadcasts).to include([ "conversation:#{conversation.id}", include(type: "message") ])
      expect(roots(turn).count).to eq(4)
      expect(roots(turn).last.span_attributes).to include("balcao.turn.outcome" => "dead_letter", "error.type" => "RuntimeError")
      expect(spans(turn).where(name: "balcao.outbound").last.span_attributes).to include("balcao.message.author" => "bot")
      expect(Rails.logger).to have_received(:error)
        .with(/\Adead letter: ProcessTurnJob [0-9a-f-]{36}, turn #{turn.id}, 3 attempts, RuntimeError\z/)
    end

    # Active Job's own lines (Retrying, Stopped retrying) carry the error's
    # message; their masking is PR-16's (SR-30).
    it "names the error by its class alone in the dead letter's line, never by its message (SR-30)" do
      lines = []
      allow(Rails.logger).to receive(:error) { |line = nil| lines << line }
      turn = inbound("meu cpf é 123.456.789-00")
      allow(AgentRunner).to receive(:new).and_raise(RuntimeError, "cpf 123.456.789-00")

      expect { run_to_the_end(turn) }.to raise_error(RuntimeError)

      expect(lines.compact.grep(/dead letter/)).to contain_exactly(end_with(", RuntimeError"))
      expect(lines.compact.join("\n")).not_to include("123.456.789-00")
    end

    it "keeps the turn's error when the fallback cannot be stored either, and says so in the log" do
      allow(Rails.logger).to receive(:error)
      turn = inbound("oi")
      allow(AgentRunner).to receive(:new).and_raise(RuntimeError, "a bug in the runner")
      allow(Message).to receive(:record_outbound!).and_raise(ActiveRecord::ConnectionFailed, "gone")

      expect { run_to_the_end(turn) }.to raise_error(RuntimeError, "a bug in the runner")

      expect(turn.reload.outbound_message).to be_nil
      expect(Rails.logger).to have_received(:error).with(/\Adead letter: turn #{turn.id}: no fallback sent: ActiveRecord::ConnectionFailed\z/)
    end

    it "carries the line of a reservation the turn stored before it broke (NFR-02)" do
      turn = inbound("reserva duas dipironas")
      reservation = create(:reservation, turn:, product: create(:product, sku: "DIP-500"))
      turn.update!(state: "failed")

      TurnProcessor.new(turn).give_up(RuntimeError.new("a bug"))

      expect(turn.reload.state).to eq("failed")
      expect(turn.outbound_message.body)
        .to end_with(FixedReply.with_reservations(FixedReply.fallback("pt-BR"), [ reservation ], "pt-BR"))
    end

    it "gives up on a turn that has its reply by doing nothing (NFR-02)" do
      turn = inbound("oi")
      perform(turn)

      expect { TurnProcessor.new(turn).give_up(RuntimeError.new("late")) }.not_to(change { [ Message.count, TraceEvent.count ] })
      expect(turn.reload.state).to eq("replied")
    end

    it "sends nothing for a turn deleted with its visitor while its job waited to try again (FR-05)" do
      allow(Rails.logger).to receive(:error)
      turn = inbound("oi")
      attempts = 0
      allow(AgentRunner).to receive(:new) do
        attempts += 1
        visitor.erase! if attempts == 2
        raise RuntimeError, "a bug in the runner"
      end

      expect { run_to_the_end(turn) }.not_to raise_error

      expect(attempts).to eq(2)
      expect(Message.where(turn_id: turn.id)).to be_empty
    end

    it "sends the fallback into the conversation a reset moved the turn to while its job waited (FR-04)" do
      allow(Rails.logger).to receive(:error)
      turn = inbound("oi")
      conversation.update!(closed_at: Time.current)
      opened = create(:conversation, visitor:)
      allow(AgentRunner).to receive(:new) do
        Turn.where(id: turn.id).update_all(conversation_id: opened.id)
        Message.where(id: turn.inbound_message_id).update_all(conversation_id: opened.id)
        raise RuntimeError, "a bug in the runner"
      end

      expect { run_to_the_end(turn) }.to raise_error(RuntimeError)

      expect(turn.reload.outbound_message).to have_attributes(conversation_id: opened.id)
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

    # The input figure counts the cache read and the cache written, as the
    # SDK's own tracer does (anthropic 2.8, Helpers::Tracing), so the panel's
    # "entrada" is the whole prompt (design §10, note of 2026-11-12).
    it "shows each model call's model, effort and usage, the input with the cache in it (FR-12)" do
      turn = inbound("tem dipirona?")

      perform(turn)

      call = spans(turn).where(name: "anthropic.messages.create").last
      expect(call.span_attributes).to include(
        "gen_ai.operation.name" => "chat", "gen_ai.provider.name" => "anthropic",
        "gen_ai.request.model" => "claude-opus-5-5", "gen_ai.request.reasoning.level" => "medium",
        "gen_ai.request.max_tokens" => 1500, "gen_ai.response.model" => "claude-opus-5-5",
        "anthropic.message.stop_reason" => "end_turn",
        "gen_ai.usage.input_tokens" => 1300 + 2900 + 10, "gen_ai.usage.output_tokens" => 60,
        "gen_ai.usage.cache_read.input_tokens" => 2900, "gen_ai.usage.cache_write.input_tokens" => 10,
        "balcao.latency_ms" => a_kind_of(Integer)
      )
    end

    it "sums the input with the cache over the attempts of a call a fallback model served, each attempt kept as it came" do
      attempts = [ iteration(model: "claude-opus-5-5", input: 40, output: 0, cache_read: 20, cache_write: 1),
                   iteration(model: "claude-sonnet-5-5", input: 60, output: 5, cache_read: 30, cache_write: 6, fallback: true) ]
      responses[1] = reply("[pt] Temos.", usage: usage(input: 60, output: 5, cache_read: 30, cache_write: 6, iterations: attempts))
      turn = inbound("tem dipirona?")

      perform(turn)

      call = spans(turn).where(name: "anthropic.messages.create").last
      expect(call.span_attributes).to include("gen_ai.usage.input_tokens" => 40 + 20 + 1 + 60 + 30 + 6,
                                              "gen_ai.usage.cache_read.input_tokens" => 50,
                                              "gen_ai.usage.cache_write.input_tokens" => 7)
      expect(call.span_attributes["anthropic.usage.iterations"].map { |entry| entry["input_tokens"] }).to eq([ 40, 60 ])
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

    # The drawings ask for them (design §10, note of 2026-11-12): the panel
    # says how many the list held ("1 resultado") and whether the text it
    # shows was cut, from figures taken before the cut.
    it "gives a tool result's length and, for a list, what it lists and how many, taken before the cut" do
      turn = inbound("tem dipirona?")

      perform(turn)

      tool = spans(turn).find_by(name: "anthropic.custom_tool_use search_products")
      content = tool.span_attributes["anthropic.tool_result.content"]
      expect(tool.span_attributes).to include("balcao.tool_result.characters" => content.length,
                                              "balcao.tool_result.unit" => "products", "balcao.tool_result.count" => 1)
    end

    it "keeps a long result's own length beside the 500 characters the trace keeps (FR-12)" do
      4.times { |index| create(:product, name: "Dipirona gotas #{index + 1}00 mg/ml, 20 ml, frasco conta-gotas") }
      turn = inbound("tem dipirona?")

      perform(turn)

      tool = spans(turn).find_by(name: "anthropic.custom_tool_use search_products")
      expect(tool.span_attributes["anthropic.tool_result.content"].length).to eq(500)
      expect(tool.span_attributes["balcao.tool_result.characters"]).to be > 500
      expect(tool.span_attributes["balcao.tool_result.count"]).to eq(5)
    end

    it "gives a refusal's length and no count" do
      responses[0] = tool_turn(tool_use("search_products", { query: " " }))
      turn = inbound("tem dipirona?")

      perform(turn)

      tool = spans(turn).find_by(name: "anthropic.custom_tool_use search_products")
      expect(tool.span_attributes).to include("error.type" => "tool_error",
                                              "balcao.tool_result.characters" => Tools::SearchProducts::EMPTY.length)
      expect(tool.span_attributes.keys).not_to include("balcao.tool_result.count", "balcao.tool_result.unit")
    end

    # The drawings' reason code (design §10, note of 2026-11-12): the panel
    # tells a rule the tool enforces from a failure by it, and words it.
    it "gives a refusal its reason code, which a tool's failure lacks" do
      responses.replace([ tool_turn(tool_use("search_products", { query: " " })), reply("[pt] Diga o nome."),
                          tool_turn(tool_use("search_products", { query: "dipirona" })), reply("[pt] Não consegui ver.") ])
      refused = inbound("tem dipirona?")
      perform(refused)

      allow(Product).to receive(:search).and_raise(ActiveRecord::StatementInvalid, "gone")
      allow(Rails.logger).to receive(:error)
      failed = inbound("e agora?")
      perform(failed)

      refusal = spans(refused).find_by(name: "anthropic.custom_tool_use search_products").span_attributes
      failure = spans(failed).find_by(name: "anthropic.custom_tool_use search_products").span_attributes
      expect(refusal).to include("error.type" => "tool_error", "balcao.tool_result.refusal" => "empty_query")
      expect(failure).to include("error.type" => "tool_error")
      expect(failure).not_to have_key("balcao.tool_result.refusal")
    end

    it "records a tool call whose input carries a NUL, and the turn completes (review finding C4 of pull request #10)" do
      responses[0] = tool_turn(tool_use("search_products", { query: "dipirona\u0000" }))
      turn = inbound("tem dipirona?")

      perform(turn)

      expect(turn.reload.state).to eq("replied")
      tool = spans(turn).find_by(name: "anthropic.custom_tool_use search_products")
      expect(tool.span_attributes["gen_ai.tool.call.arguments"]).to eq('{"query":"dipirona"}')
    end

    it "stores a reply whose text carries a NUL without it, and the turn is answered (review finding V1 of pull request #18)" do
      responses.replace([ reply("[pt] Temos\u0000 sim.") ])
      turn = inbound("tem dipirona?")

      perform(turn)

      expect(turn.reload.state).to eq("replied")
      expect(turn.outbound_message.body).to end_with("Temos sim.")
      expect(enqueued_jobs).to be_empty
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

    # Review finding C1 of pull request #11: under the lock, a running turn is
    # one a crash or a deploy interrupted.
    it "answers an earlier turn a crash left running before its own" do
      responses.replace([ reply("[pt] Temos, sim."), reply("[pt] Custa R$ 8,90.") ])
      first = inbound("tem dipirona?", at: 2.seconds.ago)
      first.update!(state: "running")
      second = inbound("e quanto custa?", at: 1.second.ago)

      perform(second)

      expect(first.reload).to have_attributes(state: "replied", outbound_message: be_present)
      expect(first.outbound_message.created_at).to be < second.reload.outbound_message.created_at
      expect(fake.requests.last.body[:messages].map { |message| message[:role] }).to eq(%w[user assistant user])
      expect { perform(first) }.not_to(change { fake.requests.size })
    end

    # Review finding C1 of pull request #18: a turn left to its own job's next
    # attempt was answered after a later turn, blind to that turn's reply.
    it "answers an earlier turn that failed before its own, so the turns keep their order" do
      responses.replace([ reply("[pt] Olá!"), reply("[pt] Temos, sim.") ])
      first = inbound("oi", at: 2.seconds.ago)
      first.update!(state: "failed")
      second = inbound("tem dipirona?", at: 1.second.ago)

      perform(second)

      expect([ first.reload.state, second.reload.state ]).to eq(%w[replied replied])
      expect(first.outbound_message.created_at).to be < second.outbound_message.created_at
      expect(fake.requests.last.body[:messages].map { |message| message[:role] }).to eq(%w[user assistant user])
    end

    it "never answers again, blind, what a later turn answered (review finding C1 of pull request #18, NFR-02)" do
      allow(Rails.logger).to receive(:error)
      responses.replace([ reply("[pt] Temos, sim."), reply("[pt] Temos dipirona, sim."), reply("[pt] Temos, sim.") ])
      first = inbound("tem dipirona?", at: 3.seconds.ago)
      second = inbound("?", at: 2.seconds.ago)
      calls = 0
      original = Message.method(:record_outbound!)
      allow(Message).to receive(:record_outbound!) do |**arguments|
        calls += 1
        raise ActiveRecord::ConnectionFailed, "gone" if calls == 1

        original.call(**arguments)
      end

      perform(first)
      perform(second)
      perform_enqueued_jobs

      again = fake.requests[2]
      texts = again && again.body[:messages].flat_map { |message| message[:content].map { |block| block[:text] } }
      expect(again.nil? || texts.include?("Temos dipirona, sim.")).to be(true)
      expect(first.reload.outbound_message.created_at).to be < second.reload.outbound_message.created_at
    end

    # Review finding C2 of pull request #18: an earlier turn whose own job is
    # gone (its worker died) and whose run by a later turn's job broke was
    # never run again.
    it "answers an earlier turn whose job is gone at the next message, even after a run of it broke" do
      allow(Rails.logger).to receive(:error)
      responses.replace(Array.new(4) { reply("[pt] Temos, sim.") })
      first = inbound("tem dipirona?", at: 3.seconds.ago)
      first.update!(state: "running")
      second = inbound("?", at: 2.seconds.ago)
      calls = 0
      original = Message.method(:record_outbound!)
      allow(Message).to receive(:record_outbound!) do |**arguments|
        calls += 1
        raise ActiveRecord::ConnectionFailed, "gone" if calls == 1

        original.call(**arguments)
      end

      perform(second)
      perform(inbound("obrigado"))

      expect(first.reload.outbound_message).to be_present
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

      # Review finding C2 of pull request #11: FR-04 names "reset" among a
      # Portuguese visitor's phrases.
      it "confirms a Portuguese visitor's \"reset\" in Portuguese, and the new conversation stays pt-BR (FR-01, FR-02, FR-04)" do
        turn = inbound("reset")

        perform(turn)

        expect(turn.reload.outbound_message.body).to eq(FixedReply.with_notice(FixedReply.command(:reset, "pt-BR"), "pt-BR"))
        expect(Conversation.current_for!(visitor).language).to eq("pt-BR")
      end

      # Review finding V1 of pull request #11: the intake picks a message's
      # conversation at receipt, before a reset waiting ahead of it has run.
      it "answers a message stored before its reset ran in the conversation the reset opened, without what came before (FR-04)" do
        responses.replace([ reply("[pt] Temos dipirona."), reply("[pt] De qual produto?") ])
        perform(inbound("tem dipirona?", at: 3.seconds.ago))
        inbound("/reiniciar", at: 2.seconds.ago)
        later = inbound("e quanto custa?", at: 1.second.ago)

        perform(later)

        current = Conversation.current_for!(visitor)
        expect(current).not_to eq(conversation)
        expect(later.reload).to have_attributes(conversation: current, outbound_message: have_attributes(conversation: current))
        expect(later.inbound_message.conversation).to eq(current)
        texts = fake.requests.last.body[:messages].flat_map { |message| message[:content] }.pluck(:text)
        expect(texts).to include("e quanto custa?")
        expect(texts).not_to include("tem dipirona?")
      end

      it "links a trace command stored before its reset ran to the conversation the reset opened (FR-04, FR-12)" do
        inbound("/reiniciar", at: 2.seconds.ago)
        trace = inbound("/trace", at: 1.second.ago)

        perform(trace)

        current = Conversation.current_for!(visitor)
        expect(trace.reload.outbound_message.body).to end_with("/trace##{current.trace_token}")
      end

      # Review finding R2 of pull request #11: a reset moves the messages sent
      # after it, a second reset among them, so each reset starts over.
      it "starts over again for a second reset sent after a message the first reset moved (FR-04)" do
        responses.replace([ reply("[pt] Temos dipirona."), reply("[pt] Em que posso ajudar?") ])
        inbound("/reiniciar", at: 4.seconds.ago)
        inbound("tem dipirona?", at: 3.seconds.ago)
        second_reset = inbound("/reiniciar", at: 2.seconds.ago)

        perform(second_reset)
        later = inbound("e quanto custa?", conversation: Conversation.current_for!(visitor))
        perform(later)

        expect(visitor.conversations.count).to eq(3)
        expect(fake.requests.last.body[:messages].flat_map { |message| message[:content] }.pluck(:text)).not_to include("tem dipirona?")
      end

      it "starts over for each of two resets sent at once, each confirmation with the notice (FR-01, FR-04)" do
        first = inbound("/reiniciar", at: 2.seconds.ago)
        second = inbound("/reiniciar", at: 1.second.ago)

        perform(second)

        expect(visitor.conversations.count).to eq(3)
        expect([ first, second ].map { |turn| turn.reload.outbound_message.body })
          .to all(eq(FixedReply.with_notice(FixedReply.command(:reset, "pt-BR"), "pt-BR")))
        expect(second.conversation).to eq(first.outbound_message.conversation)
        expect(second.outbound_message.conversation).to eq(Conversation.current_for!(visitor))
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

      # Review finding G2 of pull request #17: a trace page open on any of the
      # visitor's conversations kept showing what the deletion erased.
      it "tells the trace page of each of the visitor's conversations that it is gone" do
        conversation.update!(closed_at: Time.current)
        current = Conversation.current_for!(visitor)
        turn = inbound("apagar meus dados", conversation: current)

        expect { perform(turn) }.to have_broadcasted_to("trace:#{conversation.trace_token}").with(type: "deleted")
          .and have_broadcasted_to("trace:#{current.trace_token}").with(type: "deleted")
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

          # The token follows the "#", which no browser sends: no request line
          # carries it (review finding V3 of pull request #17, SR-11, SR-30).
          url = "#{Rails.configuration.x.public_origin}/trace##{conversation.trace_token}"
          expect(fake.requests).to be_empty
          expect(turn.reload.outbound_message.body).to eq(FixedReply.with_notice(FixedReply.command(:trace, "pt-BR", url:), "pt-BR"))
          expect(spans(turn).sole.span_attributes).to eq("balcao.command.name" => "trace")
        end
      end
    end
  end
end
