require "rails_helper"

# A Telegram visitor's turn (FR-19's outbound side, day 12): the model works
# under the chat's typing status, and the reply leaves for the chat once
# stored, by its status; the delete command's confirmation goes to the chat
# read before the deletion took the row, with what the command does not
# reach (FR-05). A web visitor's turn sends nothing to Telegram.
RSpec.describe "FR-19 FR-05 NFR-03 ProcessTurnJob on Telegram, the reply on its way to the chat" do
  include ModelResponses
  include ActiveJob::TestHelper
  include TelegramBotApi

  let(:chat_id) { 7_341_200_003 }
  let(:visitor) { create(:visitor, channel: "telegram", telegram_chat_id: chat_id.to_s, agreed_at: 1.hour.ago) }
  let(:conversation) { create(:conversation, visitor:, language: "pt-BR") }
  let(:responses) { [ reply("[pt] Temos, sim: Dipirona 500 mg, R$ 7,90.") ] }
  let(:actions) { [] }
  let!(:sent) { stub_bot_api(actions:) }

  before { allow(AgentRunner).to receive(:default_client) { FakeModel.new(responses).client } }

  def inbound(text, conversation: self.conversation, webhook_event: nil)
    message = Message.record_inbound!(conversation:, external_id: "#{conversation.visitor_id}:#{SecureRandom.random_number(10**9)}",
                                      body: text, webhook_event:)
    Turn.for_inbound!(message)
  end

  def perform(turn) = ProcessTurnJob.perform_now(turn.id)

  it "sends the model's reply to the chat once stored, after the typing status, and marks it sent" do
    turn = inbound("Vocês têm dipirona?")

    perform(turn)

    expect(sent.sole).to include("chat_id" => chat_id, "text" => turn.outbound_message.body,
                                 "link_preview_options" => { "is_disabled" => true }, "reply_markup" => { "remove_keyboard" => true })
    expect(actions).to include("chat_id" => chat_id, "action" => "typing")
    expect(turn.outbound_message.reload.status).to eq "sent"
  end

  # Review finding C1 of pull request #33: a job that answers the earlier
  # turns still waiting sent their replies only after its own turn's model.
  it "sends an earlier turn's reply before the later turn's model works, when the later job answers both (NFR-01)" do
    responses.replace([ reply("[pt] Olá! Em que posso ajudar?"), reply("[pt] Temos, sim.") ])
    first = inbound("oi")
    second = inbound("Vocês têm dipirona?")
    sent_when_second_ran = nil
    allow_any_instance_of(AgentRunner).to receive(:run).and_wrap_original do |original, turn, **options, &block|
      sent_when_second_ran = sent.size if turn.id == second.id
      original.call(turn, **options, &block)
    end

    perform(second) # its job holds the lock first and answers the first turn too

    expect(sent_when_second_ran).to eq 1
    expect(sent.map { |body| body["text"] }).to eq([ first.reload.outbound_message.body, second.reload.outbound_message.body ])
  end

  # NFR-01 runs from the update's receipt to the reply's send (M4-2): the
  # queue's wait before the update's job stored the message, and the send
  # after the reply was stored, are both part of what the visitor waits for.
  describe "the turn's latency, from the update's receipt to the reply's send (NFR-01)" do
    let(:received) { 3.seconds.ago }
    let(:event) { WebhookEvent.record!(update_id: 734_120_902, kind: "message", payload: "{}", received_at: received) }

    it "starts the turn's trace at the update's receipt" do
      turn = inbound("Vocês têm dipirona?", webhook_event: event)

      perform(turn)

      expect(TraceEvent.find_by!(turn_id: turn.id, name: "balcao.turn").started_at).to be_within(0.001).of(received)
    end

    it "counts the latency to the moment Telegram took the reply, not to the moment it was stored" do
      stub_request(:post, bot_api_url("sendMessage")).to_return do |request|
        travel(5.seconds) # the send itself takes five seconds
        sent << JSON.parse(request.body)
        bot_api_answer({ "message_id" => sent.size })
      end
      turn = inbound("Vocês têm dipirona?", webhook_event: event)

      perform(turn)

      expect(turn.outbound_message.reload.status).to eq "sent"
      expect(turn.reload.latency_ms).to be_within(1_000).of(8_000)
    end

    # The verifier's V2 on #45: a command's span opened when its job ran, so a
    # command that waited for the conversation was drawn after a later question.
    it "starts a command's trace at the update's receipt too" do
      turn = inbound("/trace", webhook_event: event)

      perform(turn)

      expect(TraceEvent.find_by!(turn_id: turn.id, name: "balcao.command").started_at).to be_within(0.001).of(received)
    end

    it "counts a command's latency to its send too" do
      stub_request(:post, bot_api_url("sendMessage")).to_return do |request|
        travel(5.seconds)
        sent << JSON.parse(request.body)
        bot_api_answer({ "message_id" => sent.size })
      end
      turn = inbound("/trace", webhook_event: event)

      perform(turn)

      expect(turn.reload.latency_ms).to be_within(1_000).of(8_000)
    end

    it "writes no latency for a reply that never left" do
      stub_request(:post, bot_api_url("sendMessage")).to_return(bot_api_error(403, "Forbidden: bot was blocked by the user"))
      turn = inbound("Vocês têm dipirona?", webhook_event: event)

      perform(turn)

      expect(turn.outbound_message.reload.status).to eq "failed"
      expect(turn.reload).to have_attributes(state: "replied", latency_ms: nil)
    end
  end

  # #45's verifier, V4 (cliente, since PR-19; M4-4 by the owner's word): the
  # trace page read "mensagem enviada" for every stored Telegram reply, one
  # Telegram refused or that failed after its attempts included. The run
  # opens the reply's delivery span as it stores the reply, and
  # Telegram::Outbound closes it as the reply leaves or fails.
  describe "the reply's way to the chat in the trace (FR-12; #45's verifier, V4)" do
    def delivery(turn) = TraceEvent.find_by(turn_id: turn.id, name: "balcao.delivery")

    it "opens it under the turn's root as the reply is stored, and closes it when Telegram takes the reply" do
      stub_request(:post, bot_api_url("sendMessage")).to_return do |request|
        travel(2.seconds)
        sent << JSON.parse(request.body)
        bot_api_answer({ "message_id" => sent.size })
      end
      turn = inbound("Vocês têm dipirona?")

      perform(turn)

      root = TraceEvent.find_by!(turn_id: turn.id, name: "balcao.turn")
      stored = TraceEvent.find_by!(turn_id: turn.id, name: "balcao.outbound")
      expect(delivery(turn)).to have_attributes(parent_span_id: root.span_id, trace_id: root.trace_id)
      expect(delivery(turn).started_at).to be_within(0.5).of(stored.finished_at)
      expect(delivery(turn).finished_at).to be_within(0.001).of(turn.outbound_message.reload.updated_at)
      expect(delivery(turn).finished_at).to be > stored.finished_at + 1
      expect(delivery(turn).span_attributes).not_to have_key("error.type")
    end

    it "closes it with the error's class when Telegram refuses the reply" do
      stub_request(:post, bot_api_url("sendMessage")).to_return(bot_api_error(403, "Forbidden: bot was blocked by the user"))
      allow(Rails.logger).to receive(:error)
      turn = inbound("Vocês têm dipirona?")

      perform(turn)

      expect(turn.outbound_message.reload.status).to eq "failed"
      expect(delivery(turn).finished_at).to be_present
      expect(delivery(turn).span_attributes).to include("error.type" => "Telegram::Client::Error")
    end

    it "leaves it open while the reply waits for its next attempt, and the trace's stream hears when it closes" do
      stub_request(:post, bot_api_url("sendMessage"))
        .to_return({ status: 502, body: "<html>Bad Gateway</html>" }).then.to_return(bot_api_answer({ "message_id" => 1 }))
      allow(Rails.logger).to receive(:error)
      turn = inbound("Vocês têm dipirona?")

      perform(turn)

      expect(delivery(turn).finished_at).to be_nil
      travel_to(turn.outbound_message.reload.next_attempt_at + 1.second) do
        expect { TelegramReplyJob.perform_now(visitor.id) }.to have_broadcasted_to("trace:#{conversation.trace_token}")
          .with(a_hash_including(type: "span", span: a_hash_including(name: "balcao.delivery", finished_at: a_kind_of(String))))
      end
      expect(delivery(turn).finished_at).to be_present
    end

    # Review finding V4 of pull request #48 (the web verifier; C2 of the Rails
    # finder): the span opened after the reply's commit, so a drain of the
    # person's replies in that window (their next message's read, a
    # TelegramReplyJob) sent the reply while no span was open, and the span
    # opened after it stayed open for good.
    describe "a drain right after the reply's commit (review finding V4 of pull request #48)" do
      def drain_after_commit
        allow_any_instance_of(TurnProcessor).to receive(:broadcast_reply).and_wrap_original do |original, *arguments|
          original.call(*arguments)
          Telegram::Outbound.new.deliver_pending(visitor)
        end
      end

      it "finds the reply's way open, and closes it as the reply leaves" do
        drain_after_commit
        turn = inbound("Vocês têm dipirona?")

        perform(turn)

        expect(sent.size).to eq 1
        expect(TraceEvent.where(turn_id: turn.id, name: "balcao.delivery").pluck(:finished_at)).to all(be_present)
        expect(delivery(turn)).to be_present
      end

      it "closes it with the error when Telegram refuses the reply in that window, a command's too" do
        stub_request(:post, bot_api_url("sendMessage")).to_return(bot_api_error(403, "Forbidden: bot was blocked by the user"))
        allow(Rails.logger).to receive(:error)
        drain_after_commit
        turns = [ inbound("Vocês têm dipirona?"), inbound("/trace") ]

        turns.each { |turn| perform(turn) }

        turns.each do |turn|
          expect(TraceEvent.where(turn_id: turn.id, name: "balcao.delivery").pluck(:finished_at)).to all(be_present)
          expect(delivery(turn).span_attributes).to include("error.type" => "Telegram::Client::Error")
        end
      end
    end

    it "opens it under a command's span too, and under the fallback of a turn the job gave up on" do
      command = inbound("/trace")
      perform(command)
      allow(Rails.logger).to receive(:error)
      given_up = inbound("Vocês têm dipirona?")
      TurnProcessor.new(given_up).give_up(RuntimeError.new("a bug"))

      expect(delivery(command).parent_span_id).to eq(TraceEvent.find_by!(turn_id: command.id, name: "balcao.command").span_id)
      expect(delivery(given_up).parent_span_id).to eq(TraceEvent.find_by!(turn_id: given_up.id, name: "balcao.turn").span_id)
    end
  end

  it "shows no typing status for a command, whose reply is at once" do
    turn = inbound("/trace")

    perform(turn)

    expect(sent.sole["text"]).to include("/trace#")
    expect(actions).to be_empty
  end

  it "sends a reply the job stored before it stopped, when the job runs again" do
    turn = inbound("Vocês têm dipirona?")
    allow(Telegram::Outbound).to receive(:new).and_raise(Interrupt)
    expect { perform(turn) }.to raise_error(Interrupt)
    expect(turn.outbound_message.status).to eq "pending"
    allow(Telegram::Outbound).to receive(:new).and_call_original

    perform(turn)

    expect(sent.map { |body| body["text"] }).to eq([ turn.outbound_message.body ])
    expect(turn.outbound_message.reload.status).to eq "sent"
  end

  # Review findings V2 and L14 of pull request #33: with encryption keys other
  # than the row's, reading the chat raised, so every turn broke before its
  # model and ended in the dead letter, and the delete command never deleted.
  describe "a chat that no longer decrypts (other encryption keys)" do
    let(:other_keys) { ActiveRecord::Encryption::DerivedSecretKeyProvider.new("another-primary-key-for-the-spec") }
    let(:errors) { [] }

    before do
      conversation # the visitor's row, written with the keys of the suite
      allow(Rails.logger).to receive(:error) { |line| errors << line }
    end

    it "still runs the turn, stores its reply and says in the log that the chat does not decrypt" do
      turn = ActiveRecord::Encryption.with_encryption_context(key_provider: other_keys) do
        inbound("Vocês têm dipirona?").tap { |own| perform(own) }
      end

      expect(turn.reload.state).to eq "replied"
      expect(sent).to be_empty
      expect(errors).to include("telegram visitor #{visitor.id}: the chat does not decrypt, " \
                                "ActiveRecord::Encryption::Errors::Decryption")
    end

    it "deletes the visitor's data all the same (FR-05)" do
      ActiveRecord::Encryption.with_encryption_context(key_provider: other_keys) { perform(inbound("/apagar")) }

      expect(Visitor.exists?(visitor.id)).to be(false)
      expect(sent).to be_empty
    end
  end

  describe "the delete command (FR-05)" do
    it "sends the confirmation to the chat read before the deletion, saying whose the app's copy is, and stores nothing" do
      earlier = inbound("oi")
      perform(earlier)
      sent.clear
      turn = inbound("/apagar")

      perform(turn)

      expect(Visitor.exists?(visitor.id)).to be(false)
      expect(Message.count).to eq 0
      expect(sent.sole).to include("chat_id" => chat_id, "text" => FixedReply.telegram_deleted("pt-BR"))
    end

    # Review finding C3 of pull request #47: the greeting leaves FR-21's
    # openers in the chat, and the confirmation, sent with no keyboard, left
    # them there after the person's data was gone (FR-19's part for M4: a
    # fixed line to a person who agreed takes the reply keyboard away).
    it "takes the reply keyboard away with the confirmation" do
      perform(inbound("/apagar"))

      expect(sent.sole).to include("text" => FixedReply.telegram_deleted("pt-BR"), "reply_markup" => { "remove_keyboard" => true })
    end

    # FR-05 as the owner decided it on 2026-11-15 (the MVP review, rows
    # 33-R1 and Q25): the confirmation leaves before the rows go, since the
    # chat lives on the visitor's row; a send that fails is tried again with
    # the job's backoff, three attempts in all, and the third deletes whether
    # or not its send left (review finding C8 of pull request #33: a send that
    # broke was lost with no line).
    describe "the confirmation before the deletion (the owner, 2026-11-15)" do
      let(:lines) { [] }

      before { allow(Rails.logger).to receive(:error) { |line| lines << line } }

      # Each send's answer in turn, 200 or a proxy's 502 page; answers the
      # list of whether the visitor's row was there at each send.
      def answers(*statuses)
        attempts = []
        stub_request(:post, bot_api_url("sendMessage")).to_return do |request|
          attempts << Visitor.exists?(visitor.id)
          sent << JSON.parse(request.body)
          status = statuses.fetch(attempts.size - 1, 200)
          status == 200 ? bot_api_answer({ "message_id" => sent.size }) : { status:, body: "<html>Bad Gateway</html>" }
        end
        attempts
      end

      it "sends it while the visitor's row is still there" do
        rows_at_send = answers(200)

        perform(inbound("/apagar"))

        expect(rows_at_send).to eq([ true ])
        expect(Visitor.exists?(visitor.id)).to be(false)
      end

      it "deletes nothing while a send that failed waits for the job's next attempt, and deletes once one leaves" do
        rows_at_send = answers(502, 200)
        turn = inbound("/apagar")

        ProcessTurnJob.perform_later(turn.id)
        perform_enqueued_jobs(only: ProcessTurnJob)

        expect(Visitor.exists?(visitor.id)).to be(true)
        expect(enqueued_jobs.sole).to include(job: ProcessTurnJob, args: [ turn.id ])

        perform_enqueued_jobs(only: ProcessTurnJob)

        expect(rows_at_send).to eq([ true, true ])
        expect(Visitor.exists?(visitor.id)).to be(false)
        expect(sent.map { |body| body["text"] }).to all(eq(FixedReply.telegram_deleted("pt-BR")))
      end

      it "deletes at the third attempt though its send failed too, and the log says so" do
        rows_at_send = answers(502, 502, 502)
        deletion = inbound("/apagar")
        ProcessTurnJob.perform_later(deletion.id)

        perform_enqueued_jobs(only: ProcessTurnJob) until enqueued_jobs.empty?

        expect(rows_at_send).to eq([ true, true, true ])
        expect(Visitor.exists?(visitor.id)).to be(false)
        expect(lines).to eq([ *(1..3).map do |n|
          "telegram fixed reply deleted: failed at attempt #{n} of 3 of turn #{deletion.id}'s job, Telegram::Client::Error (HTTP 502)"
        end, "telegram fixed reply deleted: not sent, the data deleted all the same" ])
      end

      it "deletes at the third attempt when its send broke, with a line that names the error" do
        allow_any_instance_of(Telegram::Outbound).to receive(:send_fixed).and_raise(ActiveRecord::ConnectionFailed)
        deletion = inbound("/apagar")
        ProcessTurnJob.perform_later(deletion.id)

        perform_enqueued_jobs(only: ProcessTurnJob) until enqueued_jobs.empty?

        expect(Visitor.exists?(visitor.id)).to be(false)
        expect(lines).to eq([ *(1..3).map do |n|
          "telegram fixed reply deleted: broke at attempt #{n} of 3 of turn #{deletion.id}'s job, ActiveRecord::ConnectionFailed"
        end, "telegram fixed reply deleted: not sent, the data deleted all the same" ])
      end

      # A later turn's job answers the earlier turns first (design §6.3).
      # Review finding C1 of pull request #41 (cliente): when the deletion's
      # confirmation did not leave there, the job went on to its own turn, so
      # a message sent after the request to delete reached the model, was
      # billed and answered before the data went. A deletion that waits for
      # its confirmation now holds the turns after it.
      describe "a later turn while the deletion waits (review finding C1 of pull request #41)" do
        it "answers nothing after the deletion, calls no model, and its job waits for its next attempt" do
          answers(502)
          deletion = inbound("/apagar")
          later = inbound("oi")
          expect_any_instance_of(AgentRunner).not_to receive(:run)

          perform(later)

          expect(later.reload.outbound_message).to be_nil
          expect(Visitor.exists?(visitor.id)).to be(true)
          expect(enqueued_jobs.sole).to include(job: ProcessTurnJob, args: [ later.id ])
          expect(lines).to include("earlier turn #{deletion.id}: a deletion that did not go holds the turns after it, " \
                                   "TurnProcessor::ConfirmationNotSent")

          perform(deletion)

          expect(Visitor.exists?(visitor.id)).to be(false)
          expect(Turn.exists?(later.id)).to be(false)
        end

        it "holds the later turn when the deletion's own job already failed its send" do
          answers(502, 502)
          deletion = inbound("/apagar")
          ProcessTurnJob.perform_later(deletion.id)
          perform_enqueued_jobs(only: ProcessTurnJob)
          later = inbound("oi")
          expect_any_instance_of(AgentRunner).not_to receive(:run)

          perform(later)

          expect(later.reload.outbound_message).to be_nil
          expect(Visitor.exists?(visitor.id)).to be(true)
        end

        it "holds the later turn when the deletion's send broke rather than failed, with a line naming the error" do
          allow_any_instance_of(Telegram::Outbound).to receive(:send_fixed).and_raise(ActiveRecord::ConnectionFailed)
          inbound("/apagar")
          later = inbound("oi")
          expect_any_instance_of(AgentRunner).not_to receive(:run)

          perform(later)

          expect(later.reload.outbound_message).to be_nil
          expect(lines).to include("telegram fixed reply deleted: broke at attempt 1 of 3 of turn #{later.id}'s job, " \
                                   "ActiveRecord::ConnectionFailed")
        end

        # The hunter's H3 on pull request #41 (its second part, dono): inside
        # a later turn's job the line counted that job's first attempt as the
        # confirmation's first, after the deletion's own job had failed it
        # twice. Each line now says whose job made the attempt.
        it "names in each failed send's line the job that made the attempt, the later turn's included" do
          answers(502, 502, 502)
          deletion = inbound("/apagar")
          ProcessTurnJob.perform_later(deletion.id)
          2.times { perform_enqueued_jobs(only: ProcessTurnJob) }
          later = inbound("oi")

          perform(later)

          expect(lines.grep(/deleted: failed/)).to eq([
            "telegram fixed reply deleted: failed at attempt 1 of 3 of turn #{deletion.id}'s job, Telegram::Client::Error (HTTP 502)",
            "telegram fixed reply deleted: failed at attempt 2 of 3 of turn #{deletion.id}'s job, Telegram::Client::Error (HTTP 502)",
            "telegram fixed reply deleted: failed at attempt 1 of 3 of turn #{later.id}'s job, Telegram::Client::Error (HTTP 502)"
          ])
        end

        it "holds a later command too, the trace link among them" do
          answers(502)
          inbound("/apagar")
          trace = inbound("/trace")

          perform(trace)

          expect(trace.reload.outbound_message).to be_nil
          expect(sent.map { |body| body["text"] }).to all(eq(FixedReply.telegram_deleted("pt-BR")))
        end

        it "deletes at the later job's last attempt, whether or not the confirmation left, and its turn goes with the rest" do
          answers(502, 502, 502)
          inbound("/apagar")
          later = inbound("oi")
          expect_any_instance_of(AgentRunner).not_to receive(:run)
          ProcessTurnJob.perform_later(later.id)

          3.times { perform_enqueued_jobs(only: ProcessTurnJob) }

          expect(Visitor.exists?(visitor.id)).to be(false)
          expect(Turn.exists?(later.id)).to be(false)
          expect(lines.grep(/dead letter/)).to be_empty
        end

        # The verifier's V1 on pull request #41 (cliente): a reset after the
        # waiting deletion moved the later turn into the conversation it
        # opened, whose lock the deletion's retry does not hold, so the data
        # could go while that turn's model call was in flight, and the
        # call's charge was rolled back with the usage record of a deleted
        # turn (FR-14, SR-02).
        it "holds a reset after the deletion, so no later turn moves out from under the deletion's lock" do
          answers(502, 502)
          inbound("/apagar")
          reset = inbound("/reiniciar")
          later = inbound("oi")
          expect_any_instance_of(AgentRunner).not_to receive(:run)

          perform(reset)
          perform(later)

          expect(conversation.reload.closed_at).to be_nil
          expect(later.reload.conversation_id).to eq(conversation.id)
          expect([ reset.reload.outbound_message, later.outbound_message ]).to all(be_nil)
        end
      end

      # NFR-02's accepted duplicate: sendMessage takes no idempotency key.
      it "sends it again when the deletion broke after it left, since the job runs again" do
        answers(200, 200)
        calls = 0
        allow_any_instance_of(Visitor).to receive(:erase!).and_wrap_original do |original|
          calls += 1
          calls == 1 ? raise(ActiveRecord::ConnectionFailed) : original.call
        end
        ProcessTurnJob.perform_later(inbound("/apagar").id)

        perform_enqueued_jobs(only: ProcessTurnJob) until enqueued_jobs.empty?

        expect(Visitor.exists?(visitor.id)).to be(false)
        expect(sent.size).to eq 2
      end

      # Review finding R1 of the fix review on pull request #41: the hold was
      # keyed on a confirmation that did not leave, so a deletion whose
      # confirmation left and whose rows then failed to go let a later message
      # reach the model after the visitor read "deleted".
      it "holds the later turns when the deletion broke after its confirmation left" do
        answers(200, 200)
        calls = 0
        allow_any_instance_of(Visitor).to receive(:erase!).and_wrap_original do |original|
          calls += 1
          calls == 1 ? raise(ActiveRecord::StatementInvalid, "canceling statement due to lock timeout") : original.call
        end
        deletion = inbound("/apagar")
        later = inbound("oi")
        expect_any_instance_of(AgentRunner).not_to receive(:run)

        perform(later)

        expect(later.reload.outbound_message).to be_nil
        expect(Visitor.exists?(visitor.id)).to be(true)
        expect(enqueued_jobs.sole).to include(job: ProcessTurnJob, args: [ later.id ])
        expect(lines).to include("earlier turn #{deletion.id}: a deletion that did not go holds the turns after it, " \
                                 "ActiveRecord::StatementInvalid")

        perform(deletion)

        expect(Visitor.exists?(visitor.id)).to be(false)
        expect(Turn.exists?(later.id)).to be(false)
      end

      # The hunter's H2 on pull request #41: the line was written before the
      # rows went, so a deletion that then failed was logged as done.
      it "says the data went without the confirmation only once it went" do
        answers(502, 502, 502)
        allow_any_instance_of(Visitor).to receive(:erase!).and_raise(ActiveRecord::StatementInvalid, "canceling statement")
        ProcessTurnJob.perform_later(inbound("/apagar").id)

        expect { perform_enqueued_jobs(only: ProcessTurnJob) until enqueued_jobs.empty? }.to raise_error(ActiveRecord::StatementInvalid)

        expect(Visitor.exists?(visitor.id)).to be(true)
        expect(lines.grep(/deleted all the same/)).to be_empty
      end

      # Review findings C3 and H1 of pull request #41: a deletion that reached
      # the dead letter got the generic fallback after "deleted", so nothing
      # ran it again, and no line said the turn was a deletion.
      describe "a deletion that reaches the dead letter (review findings C3 and H1 of pull request #41)" do
        def erase_breaks(times)
          calls = 0
          allow_any_instance_of(Visitor).to receive(:erase!).and_wrap_original do |original|
            calls += 1
            calls <= times ? raise(ActiveRecord::StatementInvalid, "canceling statement due to lock timeout") : original.call
          end
        end

        it "keeps no reply, with a line naming it, and the next message's job runs it again, its confirmation not again" do
          answers(200, 200, 200)
          erase_breaks(3)
          deletion = inbound("/apagar")
          ProcessTurnJob.perform_later(deletion.id)

          expect { perform_enqueued_jobs(only: ProcessTurnJob) until enqueued_jobs.empty? }.to raise_error(ActiveRecord::StatementInvalid)

          expect(Message.where(turn_id: deletion.id)).to be_empty
          expect(Visitor.exists?(visitor.id)).to be(true)
          expect(lines).to include("dead letter: turn #{deletion.id} is a deletion that did not go, ActiveRecord::StatementInvalid: " \
                                   "no reply, the sweep or the next message runs it again")
          expect(sent.map { |body| body["text"] }).to eq(Array.new(3, FixedReply.telegram_deleted("pt-BR")))

          later = inbound("oi")
          expect_any_instance_of(AgentRunner).not_to receive(:run)
          perform(later)

          expect(Visitor.exists?(visitor.id)).to be(false)
          expect(sent.size).to eq(3)
          expect(lines).to include("telegram fixed reply deleted: not sent again after the turn's 3 runs, the data deleted all the same")
        end

        it "keeps no reply for a later turn it held through that turn's last attempt" do
          answers(200, 200, 200)
          erase_breaks(3)
          deletion = inbound("/apagar")
          later = inbound("oi")
          expect_any_instance_of(AgentRunner).not_to receive(:run)
          ProcessTurnJob.perform_later(later.id)

          expect { perform_enqueued_jobs(only: ProcessTurnJob) until enqueued_jobs.empty? }.to raise_error(ProcessTurnJob::HeldByDeletion)

          expect(Message.where(turn_id: [ deletion.id, later.id ])).to be_empty
          expect(sent.map { |body| body["text"] }).not_to include(end_with(FixedReply.fallback("pt-BR")))
          expect(lines).to include("dead letter: turn #{later.id} is held by an earlier deletion: no reply, " \
                                   "the sweep or the next message runs the deletion again")
        end
      end
    end

    it "keeps the web's confirmation as it was" do
      web = create(:conversation, visitor: create(:visitor), language: "pt-BR")
      turn = Turn.for_inbound!(Message.record_inbound!(conversation: web, external_id: SecureRandom.uuid, body: "/apagar"))

      expect { perform(turn) }.to have_broadcasted_to("conversation:#{web.id}")
        .with(type: "deleted", text: FixedReply.command(:delete, "pt-BR"))
      expect(sent).to be_empty
    end
  end

  # Review finding H8 of pull request #33: a turn answered and stored whose
  # delivery broke on every attempt landed in the dead letter, its reply
  # still pending.
  it "lands no dead letter for a turn whose reply is stored, when only the delivery breaks, and tries it again later" do
    turn = inbound("Vocês têm dipirona?")
    allow_any_instance_of(Telegram::Outbound).to receive(:deliver_pending).and_raise(ActiveRecord::ConnectionFailed)
    lines = []
    allow(Rails.logger).to receive(:error) { |line| lines << line }

    ProcessTurnJob.perform_later(turn.id)
    perform_enqueued_jobs(only: ProcessTurnJob)

    expect(turn.reload.state).to eq "replied"
    expect(lines.grep(/dead letter/)).to be_empty
    expect(lines).to include("telegram replies of visitor #{visitor.id}: not sent, ActiveRecord::ConnectionFailed")
    expect(TelegramReplyJob).to have_been_enqueued.with(visitor.id)
  end

  it "sends the fallback of a turn the job gave up on (NFR-03)" do
    turn = inbound("Vocês têm dipirona?")
    allow_any_instance_of(TurnProcessor).to receive(:call).and_raise(ActiveRecord::StatementInvalid)
    allow(Rails.logger).to receive(:error)

    ProcessTurnJob.perform_later(turn.id)
    expect { perform_enqueued_jobs until enqueued_jobs.empty? }.to raise_error(ActiveRecord::StatementInvalid)

    expect(sent.sole["text"]).to end_with(FixedReply.fallback("pt-BR"))
    expect(turn.reload.outbound_message.status).to eq "sent"
  end

  it "sends nothing to Telegram for a web visitor's turn" do
    web = create(:conversation, visitor: create(:visitor))
    turn = Turn.for_inbound!(Message.record_inbound!(conversation: web, external_id: SecureRandom.uuid, body: "oi"))

    perform(turn)

    expect([ sent, actions ]).to all(be_empty)
    expect(turn.outbound_message.status).to eq "pending"
    expect(TraceEvent.where(turn_id: turn.id, name: "balcao.delivery")).to be_empty
  end
end
