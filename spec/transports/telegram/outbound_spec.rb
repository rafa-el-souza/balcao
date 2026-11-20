require "rails_helper"

# FR-19's outbound side: a reply leaves with sendMessage to the visitor's chat
# as plain text with the link preview off (threat model SR-43), cut between
# paragraphs when it passes Telegram's 4,096 characters (counted in UTF-16
# units), marked sent part by part, tried again after the wait a 429 names or
# the job's backoff, three attempts in all, and never sent again once marked
# sent (NFR-02). A person's replies leave one at a time and in order, and no
# send waits inside a job: a retry is a job scheduled for its time.
RSpec.describe "FR-19 SR-43 NFR-02 Telegram::Outbound, a reply on its way to the visitor's chat" do
  include TelegramBotApi
  include ActiveJob::TestHelper

  let(:outbound) { Telegram::Outbound.new }
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

  def seconds_taken
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  end

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
      # One clock reading: travel_to drops the fraction of a second, so two
      # readings a second boundary apart gave both replies the same time.
      now = Time.current
      second = reply("Segunda resposta.", at: now - 1.second)
      first = reply("Primeira resposta.", at: now - 2.seconds)

      outbound.deliver_pending(visitor)

      expect(sent.map { |body| body["text"] }).to eq([ "Primeira resposta.", "Segunda resposta." ])
      expect(sent).to all(include("chat_id" => chat_id, "link_preview_options" => { "is_disabled" => true },
                                  "reply_markup" => { "remove_keyboard" => true }))
      expect(sent).to all(satisfy { |body| !body.key?("parse_mode") && !body.key?("entities") })
      expect([ first.reload, second.reload ]).to all(have_attributes(status: "sent"))
    end

    # The bot's finish (FR-19's part for M4; Telegram::Buttons): a reply
    # carries its buttons, a reply cut in parts on its last part.
    it "sends a reply with the buttons of what it writes, on its last part, the parts before it taking the reply keyboard away" do
      create(:reservation, turn: nil, visitor:, code: "K7M2Q9")
      short = reply("Reservado: K7M2Q9, até 16/11 às 20:00.", at: 2.seconds.ago)
      long = reply([ "Reserva K7M2Q9.", "x" * 4_000, "y" * 4_000 ].join("\n\n"), at: 1.second.ago)
      copy = { "inline_keyboard" => [ [ { "text" => "Copiar o código K7M2Q9", "copy_text" => { "text" => "K7M2Q9" } } ] ] }

      parts = Telegram::Outbound.parts(long.body)

      outbound.deliver_pending(visitor)

      expect(parts.size).to eq 2
      expect(sent.map { |body| body["text"] }).to eq([ short.body, *parts ])
      expect(sent.map { |body| body["reply_markup"] }).to eq([ copy, { "remove_keyboard" => true }, copy ])
      expect([ short.reload.status, long.reload.status ]).to eq(%w[sent sent])
    end

    it "sends what the model wrote as it was written, markup and links included (SR-43)" do
      reply("**Dipirona** <b>R$ 7,90</b> [veja](https://evil.example)")

      outbound.deliver_pending(visitor)

      expect(sent.sole["text"]).to eq("**Dipirona** <b>R$ 7,90</b> [veja](https://evil.example)")
    end

    # NFR-01 (M4-2): the turn's latency runs to the send, so it is written
    # here, and a measure never holds the person's next replies back.
    it "writes the reply's turn its latency when the reply leaves, from the message's receipt (NFR-01)" do
      message = reply("Temos, sim.", at: 4.seconds.ago)

      outbound.deliver_pending(visitor)

      expect(message.turn.reload.latency_ms).to be_within(1_000).of(4_000)
    end

    it "sends the person's next reply when a turn's latency cannot be written, with a line naming the reply (NFR-01)" do
      now = Time.current
      first = reply("Primeira resposta.", at: now - 2.seconds)
      second = reply("Segunda resposta.", at: now - 1.second)
      allow_any_instance_of(Turn).to receive(:reply_sent!).and_raise(ActiveRecord::StatementInvalid)
      errors = []
      allow(Rails.logger).to receive(:error) { |line| errors << line }

      outbound.deliver_pending(visitor)

      expect([ first.reload.status, second.reload.status ]).to eq(%w[sent sent])
      expect(errors).to eq([ "telegram reply #{first.id}: its turn's latency not written, ActiveRecord::StatementInvalid",
                             "telegram reply #{second.id}: its turn's latency not written, ActiveRecord::StatementInvalid" ])
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

    # The retry the reply is waiting for, run when its time has come
    # (travel_to drops the fraction of a second, so one second past it).
    def retry_when_due
      travel_to(message.reload.next_attempt_at + 1.second)
      perform_enqueued_jobs(only: TelegramReplyJob)
    end

    # Review finding C3 of pull request #33: a send that had to wait held the
    # person's lock, and the worker's thread, for as long as it waited, and
    # the person's other jobs each held a thread waiting for that lock.
    it "waits for nothing itself: a 429 marks when to try again, for a job scheduled then, and the person's later replies wait behind it" do
      later = reply("Depois.", at: 1.minute.from_now)
      stub_request(:post, bot_api_url("sendMessage")).to_return(bot_api_error(429, "Too Many Requests: retry after 30", retry_after: 30))

      freeze_time do
        elapsed = seconds_taken { outbound.deliver_pending(visitor) }

        expect(elapsed).to be < 1
        expect(message.reload).to have_attributes(status: "pending", send_attempts: 1, next_attempt_at: 30.seconds.from_now)
        expect(later.reload.status).to eq "pending"
        expect(a_request(:post, bot_api_url("sendMessage"))).to have_been_made.once
        expect(TelegramReplyJob).to have_been_enqueued.with(visitor.id).at(30.seconds.from_now)
      end
    end

    it "tries again once the time a 429 names has passed, and the later replies follow in order" do
      later = reply("Depois.", at: 1.minute.from_now)
      stub_request(:post, bot_api_url("sendMessage"))
        .to_return(bot_api_error(429, "Too Many Requests: retry after 7", retry_after: 7)).then
        .to_return(bot_api_answer({ "message_id" => 1 }), bot_api_answer({ "message_id" => 2 }))
      outbound.deliver_pending(visitor)

      retry_when_due

      expect([ message.reload.status, later.reload.status ]).to eq(%w[sent sent])
      expect(a_request(:post, bot_api_url("sendMessage"))).to have_been_made.times(3)
    end

    it "does not try again before its time, whoever drains the person's replies meanwhile" do
      stub_request(:post, bot_api_url("sendMessage")).to_return(bot_api_error(429, "Too Many Requests: retry after 30", retry_after: 30))
      outbound.deliver_pending(visitor)

      outbound.deliver_pending(visitor)

      expect(a_request(:post, bot_api_url("sendMessage"))).to have_been_made.once
    end

    it "keeps a reply and the ones behind it pending through a long wait, never failing them for it" do
      later = reply("Depois.", at: 1.minute.from_now)
      stub_request(:post, bot_api_url("sendMessage")).to_return(bot_api_error(429, "Too Many Requests: retry after 600", retry_after: 600))

      outbound.deliver_pending(visitor)

      expect([ message.reload.status, later.reload.status ]).to eq(%w[pending pending])
      expect(message.next_attempt_at).to be_within(1.second).of(600.seconds.from_now)
    end

    it "tries again after the job's backoff for a failure of the way there, 3 s and then 18 s, three attempts in all, then marks it failed" do
      stub_request(:post, bot_api_url("sendMessage")).to_timeout
      allow(Rails.logger).to receive(:error)
      started = Time.current

      outbound.deliver_pending(visitor)
      expect(message.reload.next_attempt_at).to be_within(1.second).of(started + 3)
      retry_when_due
      expect(message.reload.next_attempt_at).to be_within(2.seconds).of(started + 3 + 1 + 18)
      retry_when_due

      expect(a_request(:post, bot_api_url("sendMessage"))).to have_been_made.times(3)
      expect(message.reload).to have_attributes(status: "failed", send_attempts: 3)
      expect(Rails.logger).to have_received(:error).with(/\Atelegram reply #{message.id}: failed after 3 attempts, Telegram::Client::Error \(Net::OpenTimeout\)\z/)
    end

    # FR-19 (the owner, 2026-11-15; the MVP review, rows 33-H3 and Q29).
    it "tries a 5xx in Telegram's own answer again after the job's backoff, as any failure of the way there" do
      stub_request(:post, bot_api_url("sendMessage")).to_return(bot_api_error(502, "Bad Gateway")).then
                                                      .to_return(bot_api_answer({ "message_id" => 1 }))
      started = Time.current

      outbound.deliver_pending(visitor)

      expect(message.reload).to have_attributes(status: "pending", send_attempts: 1)
      expect(message.next_attempt_at).to be_within(1.second).of(started + 3)
      retry_when_due
      expect(message.reload.status).to eq "sent"
    end

    it "marks it failed at once on any other answer that is not ok, and never logs the chat or the text" do
      stub_request(:post, bot_api_url("sendMessage")).to_return(bot_api_error(403, "Forbidden: bot was blocked by the user"))
      lines = []
      allow(Rails.logger).to receive(:error) { |line| lines << line }

      outbound.deliver_pending(visitor)

      expect(a_request(:post, bot_api_url("sendMessage"))).to have_been_made.once
      expect(enqueued_jobs).to be_empty
      expect(message.reload.status).to eq "failed"
      expect(lines.sole).to eq("telegram reply #{message.id}: failed after 1 attempt, Telegram::Client::Error (403)")
      expect(lines.join).not_to include(chat_id.to_s, "Temos")
    end

    # Review finding H11 of pull request #33: the line said neither which part
    # of a cut reply failed nor how long a 429 asked to wait.
    it "names in its failed line the part of a cut reply that failed, and the wait a 429 named" do
      long = reply(Array.new(3) { |i| "#{i} #{"y" * 3_000}" }.join("\n\n"), at: 1.minute.from_now)
      stub_request(:post, bot_api_url("sendMessage"))
        .to_return(bot_api_answer({ "message_id" => 1 }), bot_api_answer({ "message_id" => 2 })).then
        .to_return(bot_api_error(400, "Bad Request: message is too long"))
      lines = []
      allow(Rails.logger).to receive(:error) { |line| lines << line }
      outbound.deliver_pending(visitor)
      stub_request(:post, bot_api_url("sendMessage")).to_return(bot_api_error(429, "Too Many Requests: retry after 30", retry_after: 30))
      third = reply("Mais uma.", at: 2.minutes.from_now)
      outbound.deliver_pending(visitor)
      2.times { travel_to(third.reload.next_attempt_at + 1.second) { perform_enqueued_jobs(only: TelegramReplyJob) } }

      expect(lines).to eq([
        "telegram reply #{long.id}: failed after 1 attempt, Telegram::Client::Error (400), part 2 of 3",
        "telegram reply #{third.id}: failed after 3 attempts, Telegram::Client::Error (429, retry after 30 s)"
      ])
    end

    # FR-19 (the owner, 2026-11-15; the MVP review, row 33-R3): the three
    # attempts counted for the reply, so a long reply whose parts each met a
    # 429 failed at its third with its first parts delivered.
    it "counts the three attempts for each part: a part that leaves starts the count again for the next" do
      long = reply(Array.new(3) { |i| "#{i} #{"z" * 3_000}" }.join("\n\n"), at: 1.minute.from_now)
      message.update_columns(status: "sent")
      wait = bot_api_error(429, "Too Many Requests: retry after 1", retry_after: 1)
      stub_request(:post, bot_api_url("sendMessage"))
        .to_return(wait, bot_api_answer({ "message_id" => 1 }), wait, bot_api_answer({ "message_id" => 2 }),
                   wait, bot_api_answer({ "message_id" => 3 }))

      outbound.deliver_pending(visitor)
      4.times do
        at = long.reload.next_attempt_at or break
        travel_to(at + 1.second) { perform_enqueued_jobs(only: TelegramReplyJob) }
      end

      expect(long.reload).to have_attributes(status: "sent", parts_sent: 3)
      expect(a_request(:post, bot_api_url("sendMessage"))).to have_been_made.times(6)
    end

    # Review finding H7 of pull request #33: the client raises what is not the
    # network as itself, and nothing here takes it for a failure of the way
    # there; the job that sends tries again with its own backoff.
    it "leaves the reply pending, its attempt counted, when the client raises what is not the network" do
      stub_request(:post, bot_api_url("sendMessage")).to_raise(NoMethodError.new("undefined method 'bytesize' for nil"))

      expect { outbound.deliver_pending(visitor) }.to raise_error(NoMethodError)

      expect(message.reload).to have_attributes(status: "pending", send_attempts: 1, next_attempt_at: nil)
      expect(enqueued_jobs).to be_empty
    end

    # Review finding C6 of pull request #47 (the owner, 2026-11-15): a reply
    # whose every attempt broke with what is no answer of Telegram's never
    # reached its attempts, so it stayed pending and held the person's later
    # replies for good.
    it "fails a reply at the third attempt that broke, with a line naming the error's class, and the person's next reply goes" do
      later = reply("Depois.", at: 1.minute.from_now)
      lines = []
      allow(Rails.logger).to receive(:error) { |line| lines << line }
      allow(Telegram::Buttons).to receive(:for).and_call_original
      allow(Telegram::Buttons).to receive(:for).with(message).and_raise(I18n::MissingTranslationData.new(:pt, "telegram.x"))

      2.times { expect { outbound.deliver_pending(visitor) }.to raise_error(I18n::MissingTranslationData) }
      expect([ message.reload.status, later.reload.status ]).to eq(%w[pending pending])
      outbound.deliver_pending(visitor)

      expect(message.reload).to have_attributes(status: "failed", send_attempts: 3)
      expect(later.reload.status).to eq "sent"
      expect(sent.map { |body| body["text"] }).to eq([ "Depois." ])
      expect(lines).to eq([ "telegram reply #{message.id}: failed after 3 attempts that broke, I18n::MissingTranslationData" ])
    end

    # Review finding C1 of pull request #47: OpenSSL raises its one error for a
    # connection cut during the handshake or the answer too (measured on
    # 2026-11-15: "unexpected eof while reading"), and the client raised it as
    # itself, so the reply missed its three attempts and could stay pending.
    it "takes a connection cut during the TLS handshake or the answer for a failure of the way there: 3 s, 18 s, then failed" do
      lines = []
      allow(Rails.logger).to receive(:error) { |line| lines << line }
      [ "SSL_connect returned=1 errno=0 peeraddr=149.154.167.220:443 state=error: unexpected eof while reading",
        "SSL_read: unexpected eof while reading" ].each do |cut|
        message.update_columns(status: "pending", send_attempts: 0, next_attempt_at: nil)
        lines.clear
        stub_request(:post, bot_api_url("sendMessage")).to_raise(OpenSSL::SSL::SSLError.new(cut))
        started = Time.current

        outbound.deliver_pending(visitor)

        expect(message.reload).to have_attributes(status: "pending", send_attempts: 1)
        expect(message.next_attempt_at).to be_within(1.second).of(started + 3)
        2.times do
          travel_to(message.reload.next_attempt_at + 1.second)
          TelegramReplyJob.perform_now(visitor.id)
        end
        expect(message.reload).to have_attributes(status: "failed", send_attempts: 3)
        expect(lines).to eq([ "telegram reply #{message.id}: failed after 3 attempts, Telegram::Client::Error (OpenSSL::SSL::SSLError)" ])
        travel_back
      end
    end

    # Review finding V3 of pull request #48 (dono): a reply whose visitor's
    # chat does not decrypt (encryption keys other than the row's) stayed
    # pending for good, so NFR-03's sweep took it up again every minute, each
    # time with the chat's error line. Nothing can be sent to that person.
    it "fails the pending replies of a visitor whose chat does not decrypt, each with a line" do
      later = reply("Depois.", at: 1.minute.from_now)
      lines = []
      allow(Rails.logger).to receive(:error) { |line| lines << line }
      other_keys = ActiveRecord::Encryption::DerivedSecretKeyProvider.new("another-primary-key-for-the-spec")

      way = TraceEvent.create!(turn_id: message.turn_id, trace_id: "a" * 32, span_id: "b" * 16, name: "balcao.delivery",
                               started_at: 1.second.ago)

      ActiveRecord::Encryption.with_encryption_context(key_provider: other_keys) { outbound.deliver_pending(Visitor.find(visitor.id)) }

      expect([ message.reload.status, later.reload.status ]).to eq(%w[failed failed])
      expect(sent).to be_empty
      expect(lines).to include("telegram reply #{message.id}: failed, the visitor's chat cannot be read",
                               "telegram reply #{later.id}: failed, the visitor's chat cannot be read")
      # The reply's way in its trace closes with the error, so the page says
      # "mensagem não enviada" (FR-12; the fix review's note on #48).
      expect(way.reload).to have_attributes(finished_at: be_present,
                                            span_attributes: { "error.type" => "Telegram::Chat::Unreadable" })
    end

    # The fix review's sister on pull request #48: the reply's status and its
    # way's close were two writes, so a worker stopped between them left the
    # way open for good, the reply no longer pending for anything to close it.
    it "writes the reply's status and closes its way together: a worker stopped between them leaves neither" do
      way = TraceEvent.create!(turn_id: message.turn_id, trace_id: "a" * 32, span_id: "b" * 16, name: "balcao.delivery",
                               started_at: 1.second.ago)
      stub_const("WorkerKilled", Class.new(Exception)) # rubocop:disable Lint/InheritException
      allow_any_instance_of(TraceEvent).to receive(:update!).and_raise(WorkerKilled)

      expect { outbound.deliver_pending(visitor) }.to raise_error(WorkerKilled)

      expect(message.reload.status).to eq "pending"
      expect(way.reload.finished_at).to be_nil
      expect(sent.size).to eq 1
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

    # Review finding C3 of pull request #33: nothing keeps the chat of a reply
    # that is not stored, so it is tried once and waits for nothing.
    it "tries it once, waiting for nothing, when Telegram asks to wait" do
      stub_request(:post, bot_api_url("sendMessage")).to_return(bot_api_error(429, "Too Many Requests: retry after 30", retry_after: 30))
      allow(Rails.logger).to receive(:error)

      elapsed = seconds_taken { expect(outbound.send_fixed(chat, "Olá", name: :ask)).to be(false) }

      expect(elapsed).to be < 1
      expect(a_request(:post, bot_api_url("sendMessage"))).to have_been_made.once
      expect(enqueued_jobs).to be_empty
    end

    it "answers false and logs the class when it cannot be sent, raising nothing" do
      stub_request(:post, bot_api_url("sendMessage")).to_return(bot_api_error(403, "Forbidden: bot was blocked by the user"))
      allow(Rails.logger).to receive(:error)

      expect(outbound.send_fixed(chat, "Seus dados foram apagados.", name: :deleted)).to be(false)

      expect(Rails.logger).to have_received(:error).with("telegram fixed reply deleted: failed after 1 attempt, Telegram::Client::Error (403)")
    end
  end
end
