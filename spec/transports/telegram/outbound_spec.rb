require "rails_helper"

# FR-19's outbound side: a reply leaves with sendMessage to the visitor's chat
# as plain text with the link preview off (threat model SR-43), cut between
# paragraphs when it passes Telegram's 4,096 characters (counted in UTF-16
# units), marked sent part by part, tried again after the wait a 429 names or
# the job's backoff, three attempts in all, and never sent again once marked
# sent (NFR-02). A person's replies leave one at a time and in order.
RSpec.describe "FR-19 SR-43 NFR-02 Telegram::Outbound, a reply on its way to the visitor's chat" do
  include TelegramBotApi

  let(:waits) { [] }
  let(:outbound) { Telegram::Outbound.new(sleeper: ->(seconds) { waits << seconds }) }
  let(:chat_id) { 7_341_200_001 }
  let(:visitor) { create(:visitor, channel: "telegram", telegram_chat_id: chat_id.to_s, agreed_at: Time.current) }
  let(:conversation) { create(:conversation, visitor:) }
  let!(:sent) { stub_bot_api }

  def reply(body, at: Time.current)
    travel_to(at) do
      inbound = create(:message, conversation:, external_id: "#{visitor.id}:#{SecureRandom.random_number(10**9)}")
      Message.record_outbound!(turn: Turn.for_inbound!(inbound), body:)
    end
  end

  def units(text) = text.encode("UTF-16LE").bytesize / 2

  describe "the cut at 4,096 characters" do
    it "sends a reply within the limit whole" do
      expect(Telegram::Outbound.parts("Temos, sim.\n\nQuer reservar?")).to eq([ "Temos, sim.\n\nQuer reservar?" ])
    end

    it "cuts a longer reply between paragraphs, each part within the limit, and loses no paragraph" do
      paragraphs = Array.new(6) { |i| "#{i} #{"x" * 1_500}" }
      parts = Telegram::Outbound.parts(paragraphs.join("\n\n"))

      expect(parts.size).to be > 1
      expect(parts).to all(satisfy { |part| units(part) <= 4_096 })
      expect(parts.flat_map { |part| part.split("\n\n") }).to eq(paragraphs)
    end

    it "counts UTF-16 units, so a character outside the basic plane counts two" do
      emoji = "💊" * 2_049 # 2,049 characters, 4,098 units

      parts = Telegram::Outbound.parts(emoji)

      expect(parts.size).to eq 2
      expect(parts).to all(satisfy { |part| units(part) <= 4_096 })
      expect(parts.join).to eq(emoji)
    end

    it "cuts a paragraph that alone passes the limit between its lines, then its words, and sends no blank part" do
      lines = Array.new(5) { |i| "linha #{i} #{"palavra " * 120}".strip }
      parts = Telegram::Outbound.parts("#{lines.join("\n")}\n\n   \n\nfim")

      expect(parts).to all(satisfy { |part| units(part) <= 4_096 && part.strip.present? })
      expect(parts.join(" ").split).to eq("#{lines.join(" ")} fim".split)
    end
  end

  describe "a person's stored replies" do
    it "sends the pending replies oldest first, as plain text with the preview off and the agreement's keyboard taken away" do
      second = reply("Segunda resposta.", at: 1.second.ago)
      first = reply("Primeira resposta.", at: 2.seconds.ago)

      outbound.deliver_pending(visitor)

      expect(sent.map { |body| body["text"] }).to eq([ "Primeira resposta.", "Segunda resposta." ])
      expect(sent).to all(include("chat_id" => chat_id, "link_preview_options" => { "is_disabled" => true },
                                  "reply_markup" => { "remove_keyboard" => true }))
      expect(sent).to all(satisfy { |body| !body.key?("parse_mode") && !body.key?("entities") })
      expect([ first.reload, second.reload ]).to all(have_attributes(status: "sent"))
    end

    it "sends what the model wrote as it was written, markup and links included (SR-43)" do
      reply("**Dipirona** <b>R$ 7,90</b> [veja](https://evil.example)")

      outbound.deliver_pending(visitor)

      expect(sent.sole["text"]).to eq("**Dipirona** <b>R$ 7,90</b> [veja](https://evil.example)")
    end

    it "never sends again a reply marked sent (NFR-02)" do
      message = reply("Temos, sim.")
      outbound.deliver_pending(visitor)

      outbound.deliver_pending(visitor)

      expect(sent.size).to eq 1
      expect(message.reload.status).to eq "sent"
    end

    it "sends a long reply in parts, marked part by part, and a new attempt starts at the first part not sent" do
      body = Array.new(3) { |i| "#{i} #{"y" * 3_000}" }.join("\n\n")
      message = reply(body)
      message.update_columns(parts_sent: 1) # the first part left before its process stopped

      outbound.deliver_pending(visitor)

      expect(sent.map { |sent_body| sent_body["text"] }).to eq(Telegram::Outbound.parts(body).drop(1))
      expect(message.reload).to have_attributes(status: "sent", parts_sent: 3)
    end

    it "leaves the replies of the web, and of other visitors, alone" do
      web_turn = create(:turn)
      web = Message.record_outbound!(turn: web_turn, body: "Na web.")
      other = create(:visitor, channel: "telegram", telegram_chat_id: "99", agreed_at: Time.current)
      other_reply = Message.record_outbound!(turn: Turn.for_inbound!(create(:message, conversation: create(:conversation, visitor: other), external_id: "x:1")),
                                             body: "De outra pessoa.")

      outbound.deliver_pending(visitor)

      expect(sent).to be_empty
      expect([ web.reload.status, other_reply.reload.status ]).to eq(%w[pending pending])
    end

    it "does nothing for a web visitor" do
      outbound.deliver_pending(create(:visitor))

      expect(sent).to be_empty
    end
  end

  describe "a send that fails" do
    let(:message) { reply("Temos, sim.") }

    before { message }

    it "waits the time a 429 names and tries again" do
      stub_request(:post, bot_api_url("sendMessage"))
        .to_return(bot_api_error(429, "Too Many Requests: retry after 7", retry_after: 7)).then
        .to_return(bot_api_answer({ "message_id" => 1 }))

      outbound.deliver_pending(visitor)

      expect(waits).to eq [ 7 ]
      expect(message.reload.status).to eq "sent"
    end

    it "waits the job's backoff after a failure of the way there, 3 s and then 18 s, three attempts in all, then marks it failed" do
      stub_request(:post, bot_api_url("sendMessage")).to_timeout
      allow(Rails.logger).to receive(:error)

      outbound.deliver_pending(visitor)

      expect(waits).to eq [ 3, 18 ]
      expect(a_request(:post, bot_api_url("sendMessage"))).to have_been_made.times(3)
      expect(message.reload.status).to eq "failed"
      expect(Rails.logger).to have_received(:error).with(/\Atelegram reply #{message.id}: failed after 3 attempts, Telegram::Client::Error \(Net::OpenTimeout\)\z/)
    end

    it "marks it failed at once on any other answer that is not ok, and never logs the chat or the text" do
      stub_request(:post, bot_api_url("sendMessage")).to_return(bot_api_error(403, "Forbidden: bot was blocked by the user"))
      lines = []
      allow(Rails.logger).to receive(:error) { |line| lines << line }

      outbound.deliver_pending(visitor)

      expect(a_request(:post, bot_api_url("sendMessage"))).to have_been_made.once
      expect(waits).to be_empty
      expect(message.reload.status).to eq "failed"
      expect(lines.sole).to eq("telegram reply #{message.id}: failed after 1 attempt, Telegram::Client::Error (403)")
      expect(lines.join).not_to include(chat_id.to_s, "Temos")
    end

    it "marks it failed at once when the wait a 429 names would hold the worker longer than it may" do
      stub_request(:post, bot_api_url("sendMessage"))
        .to_return(bot_api_error(429, "Too Many Requests: retry after 600", retry_after: 600))
      allow(Rails.logger).to receive(:error)

      outbound.deliver_pending(visitor)

      expect(waits).to be_empty
      expect(message.reload.status).to eq "failed"
    end

    it "goes on to the person's next reply after one that failed" do
      later = reply("Depois.", at: 1.minute.from_now)
      stub_request(:post, bot_api_url("sendMessage"))
        .to_return(bot_api_error(400, "Bad Request: message is too long")).then
        .to_return(bot_api_answer({ "message_id" => 2 }))
      allow(Rails.logger).to receive(:error)

      outbound.deliver_pending(visitor)

      expect([ message.reload.status, later.reload.status ]).to eq(%w[failed sent])
    end
  end

  describe "a reply that is not stored (the ask, the fixed lines, the deletion's confirmation)" do
    let(:chat) { Telegram::Chat.new(identity: "a" * 64, id: chat_id) }

    it "sends it to the chat with the keyboard given, cut like any reply" do
      keyboard = Telegram::Outbound.agreement_keyboard("pt-BR")

      expect(outbound.send_fixed(chat, "Antes de começar…", keyboard:)).to be(true)

      expect(sent.sole).to include("chat_id" => chat_id, "text" => "Antes de começar…",
                                   "reply_markup" => { "keyboard" => [ [ { "text" => "Concordo" } ] ], "resize_keyboard" => true },
                                   "link_preview_options" => { "is_disabled" => true })
    end

    it "gives the agreement's button in the language of the ask" do
      expect(%w[pt-BR en es].map { |locale| Telegram::Outbound.agreement_keyboard(locale).dig(:keyboard, 0, 0, :text) })
        .to eq([ "Concordo", "I agree", "Acepto" ])
    end

    it "answers false and logs the class when it cannot be sent, raising nothing" do
      stub_request(:post, bot_api_url("sendMessage")).to_return(bot_api_error(403, "Forbidden: bot was blocked by the user"))
      allow(Rails.logger).to receive(:error)

      expect(outbound.send_fixed(chat, "Seus dados foram apagados.", name: :deleted)).to be(false)

      expect(Rails.logger).to have_received(:error).with("telegram fixed reply deleted: failed after 1 attempt, Telegram::Client::Error (403)")
    end
  end
end
