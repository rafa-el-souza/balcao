require "rails_helper"

# The operator links their own chat to the bot (threat model SR-35, ADR-0022):
# the runbook's command mints a deep link, and opening it sends
# "/start <token>" from the operator's private chat. The bot links that chat,
# answers with the link's fixed line in the language of the person's app, and
# stores nothing of the person as a visitor; a token that is not the pending
# link's is the /start of any person (FR-19, agreement first). The updates are
# the ones recorded from the demo bot (spec/fixtures/telegram, SR-33).
RSpec.describe "SR-35 FR-19 the operator's link, read from a Telegram update" do
  include ActiveJob::TestHelper
  include TelegramBotApi

  def fixture(name) = JSON.parse(Rails.root.join("spec/fixtures/telegram/#{name}.json").read)

  def next_update_id = @update_id = (@update_id || 734_120_900) + 1

  def start(text, language: "pt-br")
    update = fixture("start").merge("update_id" => next_update_id)
    update["message"]["text"] = text
    update["message"]["entities"] = [ { "offset" => 0, "length" => 6, "type" => "bot_command" } ]
    update["message"]["from"]["language_code"] = language
    update
  end

  def deliver(update)
    event = WebhookEvent.record!(update_id: update["update_id"], kind: "message", payload: update.to_json,
                                 identity_hash: Telegram::Inbound.new(update).identity)
    outcome = TelegramUpdateJob.perform_now(event.id)
    @event = event.reload
    outcome
  end

  let(:sender_id) { fixture("start").dig("message", "from", "id") }
  let!(:sent) { stub_bot_api }
  let(:token) { OperatorChat.link_url![/\?start=(.+)\z/, 1] }

  it "links the chat that opens the link, answers with the link's line, and stores no visitor" do
    outcome = deliver(start("/start #{token}", language: "es"))

    expect(outcome).to have_attributes(name: :linked, reply: FixedReply.operator_linked("es"), language: "es")
    expect(OperatorChat.chat_id).to eq(sender_id)
    expect(OperatorChat.language).to eq("es")
    expect(sent.map { |message| [ message["chat_id"], message["text"] ] }).to eq([ [ sender_id, FixedReply.operator_linked("es") ] ])
    expect([ Visitor.count, Conversation.count, Message.count, Turn.count ]).to all(eq 0)
    expect(@event).to have_attributes(status: "processed", payload: nil)
  end

  it "links a chat whose person is a visitor too, and their conversation is left alone" do
    deliver(fixture("agree"))
    messages = Message.count

    outcome = deliver(start("/start@BalcaoDemoBot #{token}"))

    expect(outcome.name).to eq(:linked)
    expect(OperatorChat.chat_id).to eq(sender_id)
    expect(Message.count).to eq(messages)
  end

  it "reads a token that is not the pending link's, or a spent one, as the /start of any person: the ask" do
    deliver(start("/start #{token}"))
    OperatorChat.unlink!

    [ "/start #{token}", "/start #{SecureRandom.urlsafe_base64(32)}", "/start #{token.downcase}x" ].each do |text|
      expect(deliver(start(text))).to have_attributes(name: :ask), text
    end
    expect(OperatorChat.chat_id).to be_nil
  end

  it "counts the link's message in the visitor's limits, so a flood of guesses is held there" do
    allow(EdgeLimits).to receive(:over?).and_return(false)
    allow(EdgeLimits).to receive(:over?).with("visitor/minute", anything).and_return(true)

    expect(deliver(start("/start #{token}")).name).to eq(:limit)
    expect(OperatorChat.chat_id).to be_nil
  end

  it "keeps the token out of the log" do
    lines = []
    allow(Rails.logger).to receive(:info) { |line| lines << line }

    deliver(start("/start #{token}"))

    expect(lines.join).not_to include(token)
  end
end
