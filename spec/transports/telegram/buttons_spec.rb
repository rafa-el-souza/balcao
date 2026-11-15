require "rails_helper"

# The bot's finish (FR-19's part for M4, ADR-0017): what a stored reply
# carries under it on Telegram, read from what the reply writes when it is
# sent, as the web chat stamps the codes a reply writes, so both channels send
# the same text (ADR-0017's fifth test). No button adds a kind of update (the
# first test, threat model SR-42): one copies a text or opens a link on the
# visitor's own device, or sends ordinary text down the path every message
# takes. No button carries the model's words (SR-43): a code is one of the
# visitor's own reservations, a link the conversation's own trace, a text one
# of config/openers.yml.
RSpec.describe "FR-19 FR-07 FR-12 FR-21 SR-43 Telegram::Buttons, what a reply carries under it on Telegram" do
  let(:visitor) { create(:visitor, channel: "telegram", telegram_chat_id: "7341200001", agreed_at: Time.current) }
  let(:conversation) { create(:conversation, visitor:, language: "pt-BR") }

  def reply(body, conversation: self.conversation)
    inbound = create(:message, conversation:, external_id: "#{conversation.visitor_id}:#{SecureRandom.random_number(10**9)}")
    Message.record_outbound!(turn: Turn.for_inbound!(inbound), body:)
  end

  def reservation(code, holder: visitor) = create(:reservation, turn: nil, visitor: holder, code:)

  def buttons(message) = Telegram::Buttons.for(message)

  def copy(code, label = "Copiar o código #{code}") = [ { text: label, copy_text: { text: code } } ]

  describe "a reservation's code (FR-07)" do
    it "gives each code of the visitor's own reservations the reply writes a button that copies it, in the order written" do
      reservation("K7M2Q9")
      reservation("P4X8RT")
      reservation("ZZ2233") # held, but not written

      message = reply("Reservei os dois: P4X8RT (Dipirona) e K7M2Q9 (Loratadina), até 16/11 às 20:00.")

      expect(buttons(message)).to eq(inline_keyboard: [ copy("P4X8RT"), copy("K7M2Q9") ])
    end

    it "gives none to a code that is no reservation of the visitor's, nor to one inside a longer word" do
      reservation("K7M2Q9", holder: create(:visitor, channel: "telegram", telegram_chat_id: "99", agreed_at: Time.current))
      reservation("P4X8RT")

      message = reply("Seu código é K7M2Q9, e o pedido XP4X8RT está separado.")

      expect(buttons(message)).to eq(Telegram::Outbound::REMOVE_KEYBOARD)
    end

    it "names the button in the conversation's language" do
      reservation("K7M2Q9")
      conversation.update!(language: "es")

      expect(buttons(reply("Tu reserva K7M2Q9 está lista."))).to eq(inline_keyboard: [ copy("K7M2Q9", "Copiar el código K7M2Q9") ])
      conversation.update!(language: "en")
      expect(buttons(reply("Your reservation K7M2Q9 is ready."))).to eq(inline_keyboard: [ copy("K7M2Q9", "Copy the code K7M2Q9") ])
    end

    it "gives the reply a turn answers from its stored reservations their buttons too (NFR-02)" do
      held = reservation("K7M2Q9")

      message = reply(FixedReply.reservations([ held ], "pt-BR"))

      expect(buttons(message)).to eq(inline_keyboard: [ copy("K7M2Q9") ])
    end
  end

  describe "the trace (FR-12)" do
    it "gives /trace's reply a button that opens the conversation's trace page" do
      turn = Turn.for_inbound!(Message.record_inbound!(conversation:, external_id: "#{visitor.id}:1", body: "/trace"))
      TurnProcessor.new(turn).call
      message = turn.outbound_message

      expect(message.body).to include(conversation.trace_url)
      expect(buttons(message)).to eq(inline_keyboard: [ [ { text: "Abrir o trace", url: conversation.trace_url } ] ])
    end

    it "gives none to a link of another conversation's trace, nor to the page's own link with more after the token" do
      other = create(:conversation, visitor: create(:visitor, channel: "telegram", telegram_chat_id: "99", agreed_at: Time.current))

      expect(buttons(reply("Veja: #{other.trace_url}"))).to eq(Telegram::Outbound::REMOVE_KEYBOARD)
      expect(buttons(reply("Veja: #{conversation.trace_url}x"))).to eq(Telegram::Outbound::REMOVE_KEYBOARD)
    end

    it "puts the codes' buttons first when a reply writes both" do
      reservation("K7M2Q9")

      message = reply("Reserva K7M2Q9. Como eu funciono: #{conversation.trace_url}")

      expect(buttons(message)).to eq(inline_keyboard: [ copy("K7M2Q9"), [ { text: "Abrir o trace", url: conversation.trace_url } ] ])
    end
  end

  describe "the openers under the greeting (FR-21)" do
    let(:openers) do
      { keyboard: Openers.current.all.map { |opener| [ { text: opener.text } ] }, resize_keyboard: true, one_time_keyboard: true }
    end

    it "gives the greeting the three openers of config/openers.yml as a reply keyboard that hides once tapped" do
      expect(openers[:keyboard].flatten.pluck(:text))
        .to eq([ "tem dipirona?", "¿hacen entregas en Santa Tereza?", "tem dipirona e posso dar pro meu filho de 3 anos?" ])

      expect(buttons(reply(FixedReply.greeting("pt-BR")))).to eq(openers)
    end

    it "gives them to /start's greeting with the notice before it, in each language" do
      %w[pt-BR en es].each do |language|
        fresh = create(:conversation, visitor: create(:visitor, channel: "telegram", telegram_chat_id: "8", agreed_at: Time.current),
                                      language:)
        turn = Turn.for_inbound!(Message.record_inbound!(conversation: fresh, external_id: "#{fresh.visitor_id}:1", body: "/start"))
        TurnProcessor.new(turn).call

        expect(turn.outbound_message.body).to eq(FixedReply.with_notice(FixedReply.greeting(language), language))
        expect(buttons(turn.outbound_message)).to eq(openers)
      end
    end

    it "gives none to a reply that only quotes the greeting" do
      expect(buttons(reply("Você disse: #{FixedReply.greeting("pt-BR")}"))).to eq(Telegram::Outbound::REMOVE_KEYBOARD)
    end
  end

  it "takes the reply keyboard away from any other reply" do
    expect(buttons(reply("Temos, sim: Dipirona 500 mg, R$ 7,90."))).to eq(remove_keyboard: true)
  end
end
