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

  def inbound(text, conversation: self.conversation)
    message = Message.record_inbound!(conversation:, external_id: "#{conversation.visitor_id}:#{SecureRandom.random_number(10**9)}", body: text)
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
      expect(sent.sole).not_to have_key("reply_markup")
    end

    it "keeps the web's confirmation as it was" do
      web = create(:conversation, visitor: create(:visitor), language: "pt-BR")
      turn = Turn.for_inbound!(Message.record_inbound!(conversation: web, external_id: SecureRandom.uuid, body: "/apagar"))

      expect { perform(turn) }.to have_broadcasted_to("conversation:#{web.id}")
        .with(type: "deleted", text: FixedReply.command(:delete, "pt-BR"))
      expect(sent).to be_empty
    end
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
  end
end
