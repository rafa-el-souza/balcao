require "rails_helper"

# FR-19's inbound side, from the stored update to what it makes of the
# conversation (threat model SR-07, SR-10, SR-41, SR-42; NFR-02): agreement
# first, then a text is a turn like the web chat's. The updates are the ones
# recorded from the demo bot, with invented ids, names and usernames
# (spec/fixtures/telegram, SR-33); the variants below change one field of
# them to make what a private chat with the bot cannot record.
RSpec.describe "FR-19 SR-10 SR-41 SR-42 TelegramUpdateJob, reading a stored update" do
  include ActiveJob::TestHelper
  include ModelResponses
  include TelegramBotApi

  RECORDED = %w[start text agree help photo emoji voice photo_caption sticker].freeze

  def fixture(name) = JSON.parse(Rails.root.join("spec/fixtures/telegram/#{name}.json").read)

  # The update with its message changed by the block, under a fresh update_id.
  def variant(name, update_id: next_update_id)
    update = fixture(name).merge("update_id" => update_id)
    yield update["message"] if block_given?
    update
  end

  def next_update_id = @update_id = (@update_id || 734_120_500) + 1

  # Stores the update as the webhook does and reads it as the queue would;
  # returns what it made.
  def deliver(update, kind: (update.keys - [ "update_id" ]).first)
    event = store(update, kind:)
    outcome = TelegramUpdateJob.perform_now(event.id)
    @event = event.reload
    outcome
  end

  # Stores the update as the webhook does, with the sender's hashed identity
  # when the update is one the bot uses.
  def store(update, kind: (update.keys - [ "update_id" ]).first)
    WebhookEvent.record!(update_id: update["update_id"], kind:, payload: update.to_json,
                         identity_hash: Telegram::Inbound.new(update).identity)
  end

  let(:sender_id) { fixture("text").dig("message", "from", "id") }
  # What the Bot API received, in order (PR-19 sends every reply).
  let!(:sent) { stub_bot_api }
  let(:identity) { Digest::SHA256.hexdigest("#{Rails.configuration.x.identity_pepper}#{sender_id}") }

  def agreed! = deliver(fixture("agree"))

  def stored_nothing
    expect([ Visitor.count, Conversation.count, Message.count, Turn.count, TraceEvent.count ]).to all(eq 0)
    expect(enqueued_jobs.map { |job| job["job_class"] }).not_to include("ProcessTurnJob")
  end

  describe "the updates the bot uses (SR-42)" do
    it "uses every update recorded from a private chat with the demo bot" do
      RECORDED.each do |name|
        expect(Telegram::Inbound.new(fixture(name)).identity).to eq(identity), name
      end
    end

    {
      "a group's message" => ->(message) { message["chat"] = { "id" => -100_734_120, "title" => "Grupo", "type" => "group" } },
      "a channel's post" => ->(message) { message["chat"] = { "id" => -100_734_121, "title" => "Canal", "type" => "channel" } },
      "a private chat that is not the sender's" => ->(message) { message["chat"] = message["chat"].merge("id" => 7_341_200_999) },
      "a bot's message" => ->(message) { message["from"] = message["from"].merge("is_bot" => true) },
      "a message with no sender" => ->(message) { message.delete("from") },
      "a message without Telegram's id of it" => ->(message) { message["message_id"] = 0 }
    }.each do |label, change|
      it "drops #{label}: no visitor, no turn, no reply, and the update is stripped" do
        agreed!
        before = [ Visitor.count, Message.count, Turn.count ]

        outcome = deliver(variant("text", &change))

        expect(outcome).to have_attributes(name: :dropped, reply: nil)
        expect([ Visitor.count, Message.count, Turn.count ]).to eq(before)
        expect(@event).to have_attributes(status: "ignored", payload: nil)
      end
    end

    it "drops an edited message and a button's callback, kinds the webhook does not ask for" do
      [ fixture("edited_message"),
        { "update_id" => next_update_id, "callback_query" => { "id" => "1", "from" => fixture("text")["message"]["from"], "data" => "x" } } ].each do |update|
        expect(deliver(update)).to have_attributes(name: :dropped, reply: nil)
      end
      stored_nothing
    end

    it "gives a service message, which the app writes, no reply and no count" do
      update = variant("text") { |message| message.delete("text") && message["write_access_allowed"] = { "from_request" => true } }

      expect(deliver(update)).to have_attributes(name: :service, reply: nil, status: "ignored")
      stored_nothing
    end
  end

  # FR-19, agreement first (the owner, 2026-11-14).
  describe "a person the bot holds no row of" do
    %w[start text photo sticker voice].each do |name|
      it "gets the ask for #{name}, in the language of the person's app, and nothing of them is stored" do
        outcome = deliver(fixture(name))

        expect(outcome).to have_attributes(name: :ask, reply: FixedReply.ask("pt-BR"), language: "pt-BR")
        stored_nothing
        expect(@event).to have_attributes(status: "processed", payload: nil)
      end
    end

    { "en" => "en", "en-US" => "en", "es-419" => "es", "pt" => "pt-BR", "fr" => "pt-BR", nil => "pt-BR" }.each do |code, locale|
      it "asks in #{locale} when the app's language is #{code.inspect}" do
        update = variant("start") { |message| message["from"] = message["from"].merge("language_code" => code).compact }

        expect(deliver(update)).to have_attributes(name: :ask, language: locale, reply: FixedReply.ask(locale))
      end
    end

    it "answers /help and the delete command as always, storing nothing" do
      expect(deliver(fixture("help"))).to have_attributes(name: :help, reply: FixedReply.help("pt-BR"))
      deleted = deliver(variant("text") { |message| message["text"] = "/apagar" })
      expect(deleted).to have_attributes(name: :deleted, reply: FixedReply.telegram_deleted("pt-BR"))
      stored_nothing
    end

    it "takes no caption for an agreement: a photo captioned with the phrase gets the ask" do
      expect(deliver(fixture("photo_caption"))).to have_attributes(name: :ask)
      update = variant("photo_caption") { |message| message["caption"] = "Concordo" }

      expect(deliver(update)).to have_attributes(name: :ask)
      stored_nothing
    end

    it "is asked again after the delete command took the row away (FR-05)" do
      agreed!
      Visitor.sole.erase!

      expect(deliver(variant("text"))).to have_attributes(name: :ask)
    end
  end

  describe "the agreement" do
    it "creates the row with the encrypted chat id and the time, the first conversation in the app's language, and the greeting as its first reply" do
      at = Time.zone.local(2026, 11, 14, 15, 0)
      outcome = travel_to(at) { agreed! }

      # The greeting is a stored reply, sent by its status (review finding T5
      # of pull request #32), so the outcome names nothing to send.
      expect(outcome).to have_attributes(name: :agreed, reply: nil, language: "pt-BR")
      visitor = Visitor.sole
      expect(visitor).to have_attributes(channel: "telegram", identity_hash: identity, telegram_chat_id: sender_id.to_s, agreed_at: at)
      conversation = Conversation.sole
      expect(conversation).to have_attributes(visitor:, language: "pt-BR")
      inbound, outbound = conversation.messages.order(:created_at, :direction).partition(&:inbound?).map(&:sole)
      expect(inbound).to have_attributes(body: "Concordo", source: "command", channel: "telegram",
                                         external_id: "#{visitor.id}:3", webhook_event_id: @event.id)
      expect(outbound).to have_attributes(body: FixedReply.greeting("pt-BR"), status: "sent")
      # The system's text, which the history marks as the system's (M2-11a).
      expect(outbound.authored).to have_attributes(attendant: nil, system: FixedReply.greeting("pt-BR"))
      expect(Turn.sole).to have_attributes(state: "replied", inbound_message: inbound)
      command = TraceEvent.find_by!(name: "balcao.command")
      expect(command.span_attributes).to eq("balcao.command.name" => "agree")
      # The greeting's way to the chat (FR-12; #45's verifier, V4): open as it
      # is stored, closed as it leaves.
      expect(TraceEvent.find_by!(name: "balcao.delivery"))
        .to have_attributes(parent_span_id: command.span_id, finished_at: be_present, span_attributes: {})
      expect(enqueued_jobs.map { |job| job["job_class"] }).not_to include("ProcessTurnJob")
    end

    # NFR-01 runs from the update's receipt to the reply's send (M4-2): the
    # greeting is the agreement's reply, sent by its status after the read.
    it "gives the agreement's turn its latency from the update's receipt to the greeting's send (NFR-01)" do
      stub_request(:post, bot_api_url("sendMessage")).to_return do |request|
        travel(5.seconds) # the send itself takes five seconds
        sent << JSON.parse(request.body)
        bot_api_answer({ "message_id" => sent.size })
      end
      event = travel_to(3.seconds.ago) { store(fixture("agree")) }

      TelegramUpdateJob.perform_now(event.id)

      expect(Message.outbound.sole.status).to eq "sent"
      expect(Turn.sole.latency_ms).to be_within(1_000).of(8_000)
      # The verifier's V2 on #45: the agreement's span starts at the receipt too.
      expect(TraceEvent.find_by!(name: "balcao.command").started_at).to be_within(0.001).of(event.received_at)
    end

    it "starts the first conversation in English for an English app, and the greeting follows" do
      update = variant("agree") do |message|
        message["text"] = "I agree"
        message["from"] = message["from"].merge("language_code" => "en")
      end

      expect(deliver(update)).to have_attributes(name: :agreed, reply: nil, language: "en")
      expect(Conversation.sole.language).to eq("en")
      expect(sent.sole["text"]).to eq(FixedReply.greeting("en"))
    end

    it "leaves the next replies without the notice, which came with the ask (FR-01)" do
      agreed!
      allow(AgentRunner).to receive(:default_client) { FakeModel.new([ reply("[pt] Temos, sim.") ]).client }

      deliver(fixture("text"))
      perform_enqueued_jobs(only: ProcessTurnJob)

      expect(Message.outbound.order(:created_at).last.body).to eq("Temos, sim.")
    end

    it "keeps the chat id as ciphertext, and no other row holds the raw id (SR-10, SR-41)" do
      agreed!
      deliver(fixture("text"))

      raw = sender_id.to_s
      dump = %w[visitors conversations messages turns trace_events webhook_events].map do |table|
        Visitor.connection.select_all("SELECT * FROM #{table}").rows.flatten.join(" ")
      end.join(" ")
      expect(dump).not_to include(raw)
      expect(dump).not_to include("dipirona")
    end
  end

  describe "a visitor who agreed" do
    before { agreed! }

    it "makes a text a turn, keyed by the visitor and the message id, enqueued for ProcessTurnJob" do
      outcome = deliver(fixture("text"))

      visitor = Visitor.sole
      message = Message.find_by!(external_id: "#{visitor.id}:2")
      expect(outcome).to have_attributes(name: :turn, reply: nil)
      expect(message).to have_attributes(body: "Vocês têm dipirona?", channel: "telegram", source: "text", webhook_event_id: @event.id)
      expect(ProcessTurnJob).to have_been_enqueued.with(Turn.find_by!(inbound_message: message).id)
      expect(@event).to have_attributes(status: "processed", payload: nil)
    end

    it "stores a message sent again under another update once (SR-07, NFR-02)" do
      deliver(fixture("text"))
      expect { deliver(variant("text")) }.not_to change(Message, :count)
    end

    it "takes the agreement's phrase as a message like any other once the row exists" do
      expect(deliver(variant("agree"))).to have_attributes(name: :turn)
      expect(Visitor.count).to eq(1)
    end

    it "makes /start a turn, which TurnProcessor answers with the greeting" do
      expect(deliver(variant("start"))).to have_attributes(name: :turn)
    end

    %w[photo sticker voice].each do |name|
      it "answers #{name} with the line that it reads text here, fetching nothing and storing nothing" do
        before = Message.count

        outcome = deliver(fixture(name))

        expect(outcome).to have_attributes(name: :not_text, reply: FixedReply.not_text("pt-BR"))
        expect(Message.count).to eq(before)
        expect(a_request(:any, %r{api\.telegram\.org/(file/|bot[^/]+/getFile)})).not_to have_been_made
      end
    end

    it "answers a shared contact with that line, and its number reaches no row (SR-10)" do
      update = variant("text") do |message|
        message.delete("text")
        message["contact"] = { "phone_number" => "+5531987654321", "first_name" => "Contato", "user_id" => 7_341_200_777 }
      end

      expect(deliver(update)).to have_attributes(name: :not_text)
      dump = %w[messages webhook_events].map { |table| Message.connection.select_all("SELECT * FROM #{table}").rows.flatten.join(" ") }.join
      expect(dump).not_to include("987654321")
    end

    it "answers a text over 1,000 characters with its line, storing nothing" do
      before = Message.count

      outcome = deliver(variant("text") { |message| message["text"] = "a" * 1_001 })

      expect(outcome).to have_attributes(name: :too_long, reply: FixedReply.too_long("pt-BR"))
      expect(Message.count).to eq(before)
      expect(deliver(variant("text") { |message| message["text"] = "a" * 1_000 })).to have_attributes(name: :turn)
    end

    it "answers in the conversation's language once it moved (FR-02)" do
      Conversation.sole.update!(language: "es")

      expect(deliver(fixture("photo"))).to have_attributes(reply: FixedReply.not_text("es"))
    end

    # Review finding C1 (T1) of pull request #32: a deletion that commits
    # between the read of the row and the next step (the person's own
    # /apagar, run by ProcessTurnJob under the conversation's lock, or the
    # nightly purge) left a row made again, without the agreement or the chat.
    it "makes no row again for a person whose row went right after it was read, and asks instead" do
      erased = false
      allow(Visitor).to receive(:find_by).and_wrap_original do |original, *args, **kwargs|
        original.call(*args, **kwargs).tap do |row|
          next unless row && !erased

          erased = true
          row.erase!
        end
      end

      outcome = deliver(fixture("text"))

      expect(Visitor.where(channel: "telegram")).to be_empty
      expect(outcome).to have_attributes(name: :ask)
      expect(enqueued_jobs.map { |job| job["job_class"] }).not_to include("ProcessTurnJob")
    end

    it "marks the visitor seen at every message, which keeps it from the seven-day purge (FR-15)" do
      later = 3.days.from_now
      travel_to(later) { deliver(fixture("sticker")) }

      expect(Visitor.sole.last_seen_at).to be_within(1.second).of(later)
    end
  end

  # FR-14 by the visitor's identity: every message counts, whatever its kind,
  # before the agreement too; past a limit nothing is read, and the limit's
  # line goes at most once a minute.
  describe "the limits (FR-14)" do
    let(:base) { Time.zone.local(2026, 11, 14, 15, 0) }

    around do |example|
      store = Rack::Attack.cache.store
      Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
      example.run
    ensure
      Rack::Attack.cache.store = store
      travel_back
    end

    before { travel_to(base) }

    it "counts every message by the identity, before the agreement too, and answers the 11th of a minute with the line once" do
      outcomes = 10.times.map { |index| deliver(variant(index.even? ? "sticker" : "text")) }
      expect(outcomes.map(&:name).uniq).to eq([ :ask ])

      eleventh = deliver(variant("agree"))
      twelfth = deliver(variant("text"))

      expect(eleventh).to have_attributes(name: :limit, reply: I18n.t("limits.now", locale: "pt-BR"))
      expect(twelfth).to have_attributes(name: :limit_silent, reply: nil)
      stored_nothing
    end

    # Review finding C2 of pull request #47: a send the client raised as
    # itself broke the read after the update was read, so the update was read
    # again, its message counted again and its line sent again, and at the
    # third attempt it was given up.
    it "logs a send that breaks by its class and goes on with the read, which counts the message once" do
      stub_request(:post, bot_api_url("sendMessage")).to_raise(NoMethodError.new("undefined method 'bytesize' for nil"))
      lines = []
      allow(Rails.logger).to receive(:error) { |line| lines << line }

      deliver(fixture("start"))
      perform_enqueued_jobs(only: TelegramUpdateJob)

      expect(@event.reload).to have_attributes(status: "processed", payload: nil)
      expect(Rack::Attack.cache.store.read("limits:visitor/minute:#{identity}").to_i).to eq 1
      expect(a_request(:post, bot_api_url("sendMessage"))).to have_been_made.once
      expect(lines).to eq([ "telegram update #{@event.update_id}: replies not sent, NoMethodError" ])
    end

    it "tries a stored reply that a send left pending again a minute later" do
      agreed!
      visitor = Visitor.sole
      Message.outbound.sole.update_columns(status: "pending", parts_sent: 0)
      stub_request(:post, bot_api_url("sendMessage")).to_raise(NoMethodError.new("undefined method 'bytesize' for nil"))
      allow(Rails.logger).to receive(:error)

      deliver(fixture("photo"))

      expect(@event.reload.status).to eq "processed"
      expect(Message.outbound.sole.status).to eq "pending"
      expect(TelegramReplyJob).to have_been_enqueued.with(visitor.id).at(be_within(1.second).of(1.minute.from_now))
    end

    it "says the day's limit after 40 messages in a day, in the visitor's language" do
      agreed!
      Conversation.sole.update!(language: "en")
      39.times do |index|
        travel_to(base + ((index + 1) * 2).minutes)
        deliver(variant(index.even? ? "photo" : "sticker"))
      end

      travel_to(base + 3.hours)
      expect(deliver(variant("text"))).to have_attributes(name: :limit, reply: I18n.t("limits.today", locale: "en"))
    end
  end

  # FR-19's outbound side, day 12: every reply leaves for the person's chat
  # as plain text with the preview off (SR-43). A reply that is not stored
  # goes to the chat of the update being read; a stored one by its status.
  describe "the replies" do
    def texts = sent.map { |body| body["text"] }

    it "sends the ask with its one button, in the language of the person's app, and stores nothing" do
      update = variant("start") { |message| message["from"] = message["from"].merge("language_code" => "es") }

      deliver(update)

      expect(sent.sole).to include("chat_id" => sender_id, "text" => FixedReply.ask("es"),
                                   "reply_markup" => { "keyboard" => [ [ { "text" => "Acepto" } ] ], "resize_keyboard" => true },
                                   "link_preview_options" => { "is_disabled" => true })
      stored_nothing
    end

    # FR-21 on Telegram (M4): the openers take the agreement's button's place.
    it "sends the greeting the agreement stored with FR-21's openers in the button's place, and marks it sent" do
      agreed!

      expect(sent.sole).to include("chat_id" => sender_id, "text" => FixedReply.greeting("pt-BR"),
                                   "reply_markup" => { "keyboard" => Openers.current.all.map { |opener| [ { "text" => opener.text } ] },
                                                       "resize_keyboard" => true, "one_time_keyboard" => true })
      expect(Message.outbound.sole).to have_attributes(status: "sent", parts_sent: 1)
    end

    # The fix review's R1 on pull request #47: a drain that broke before the
    # update's fixed line kept the line from leaving, where the read's retry
    # had sent it before C2's fix.
    it "sends the fixed line when the drain before it breaks once" do
      agreed!
      Message.outbound.sole.update_columns(status: "pending", parts_sent: 0)
      broke = false
      allow(Telegram::Buttons).to receive(:for).and_wrap_original do |original, message|
        next original.call(message) if broke

        broke = true
        raise ActiveRecord::QueryCanceled, "canceling statement due to statement timeout"
      end
      lines = []
      allow(Rails.logger).to receive(:error) { |line| lines << line }

      deliver(fixture("photo"))
      perform_enqueued_jobs

      expect(sent.map { |body| body["text"] }).to include(FixedReply.not_text("pt-BR"))
      # The close's C2s of M4-6a: the line said "replies not sent" for a
      # fixed line that had left; it names the stored replies alone.
      expect(lines).to include("telegram update #{@event.update_id}: stored replies not sent, ActiveRecord::QueryCanceled")
    end

    # Review finding C3 of pull request #47: the openers outlived the
    # person's data when the deletion's confirmation came with no keyboard.
    it "takes the openers away with the deletion's confirmation" do
      agreed!

      deliver(variant("text") { |message| message["text"] = "/apagar" })
      perform_enqueued_jobs(only: ProcessTurnJob)

      expect(Visitor.count).to eq 0
      expect(sent.find { |body| body["text"] == FixedReply.telegram_deleted("pt-BR") })
        .to include("reply_markup" => { "remove_keyboard" => true })
    end

    # FR-21 on Telegram: a tap on an opener sends its text as an ordinary
    # message, a turn like any other, and the reply takes the openers away.
    it "takes a tapped opener's text as a turn, and its reply takes the openers away" do
      allow(AgentRunner).to receive(:default_client) { FakeModel.new([ reply("[pt] Temos, sim: Dipirona 500 mg, R$ 7,90.") ]).client }
      agreed!
      opener = Openers.current.fetch("stock_pt")

      deliver(variant("text") { |message| message["text"] = opener.text })
      perform_enqueued_jobs(only: ProcessTurnJob)

      expect(Message.inbound.where(source: "text").sole.body).to eq(opener.text)
      expect(sent.last).to include("text" => "Temos, sim: Dipirona 500 mg, R$ 7,90.", "reply_markup" => { "remove_keyboard" => true })
    end

    # Review finding T5 of pull request #32: an agreement read again (its
    # strip failed, or a second job ran) names a turn, not the greeting.
    it "sends the greeting once when the agreement is read again" do
      agreed = store(variant("agree"))
      breaking = true
      allow_any_instance_of(WebhookEvent).to receive(:strip!).and_wrap_original do |original, *args|
        raise ActiveRecord::ConnectionFailed if breaking

        original.call(*args)
      end
      lines = []
      allow(Rails.logger).to receive(:info) { |line| lines << line }
      TelegramUpdateJob.perform_now(agreed.id) # the strip breaks, and Active Job enqueues the next attempt
      breaking = false

      perform_enqueued_jobs(only: TelegramUpdateJob)

      expect(agreed.reload).to have_attributes(status: "processed", payload: nil)
      expect(lines).to include("telegram update #{agreed.update_id}: turn")
      expect(texts).to eq([ FixedReply.greeting("pt-BR") ])
      expect(Message.outbound.sole.status).to eq "sent"
    end

    it "answers /help and the deletion before the agreement without touching the button, the deletion saying whose the app's copy is (FR-05)" do
      deliver(fixture("help"))
      deliver(variant("text") { |message| message["text"] = "/apagar" })

      expect(texts).to eq([ FixedReply.help("pt-BR"), FixedReply.telegram_deleted("pt-BR") ])
      expect(sent).to all(satisfy { |body| !body.key?("reply_markup") })
      expect(FixedReply.telegram_deleted("pt-BR")).to start_with(FixedReply.command(:delete, "pt-BR"))
        .and include(I18n.t("telegram.own_copy", locale: "pt-BR"))
    end

    it "sends a visitor's fixed lines with the button taken away" do
      agreed!
      deliver(fixture("photo"))
      deliver(variant("text") { |message| message["text"] = "a" * 1_001 })

      expect(texts.last(2)).to eq([ FixedReply.not_text("pt-BR"), FixedReply.too_long("pt-BR") ])
      expect(sent.last(2)).to all(include("reply_markup" => { "remove_keyboard" => true }))
    end

    # Review finding C2 of pull request #33: the update's own line left before
    # an older reply still pending, in two holds of the lock.
    it "sends a stored reply still pending before a later update's fixed line" do
      agreed!
      visitor = Visitor.sole
      conversation = visitor.conversations.sole
      earlier = Turn.for_inbound!(Message.record_inbound!(conversation:, external_id: "#{visitor.id}:999999", body: "oi"))
      stored = Message.record_outbound!(turn: earlier, body: "Olá! Em que posso ajudar?")
      sent.clear
      allow(AdvisoryLock).to receive(:hold).and_call_original

      deliver(fixture("sticker"))

      expect(texts).to eq([ stored.body, FixedReply.not_text(conversation.language) ])
      expect(AdvisoryLock).to have_received(:hold).with("telegram-send:#{identity}").once
    end

    # Review finding V2 of pull request #33: with encryption keys other than
    # the row's, the read broke after the line and was tried again, the line
    # going out at each attempt.
    it "reads the update and sends a visitor's fixed line once when the visitor's chat no longer decrypts" do
      agreed!
      sent.clear
      other_keys = ActiveRecord::Encryption::DerivedSecretKeyProvider.new("another-primary-key-for-the-spec")
      errors = []
      allow(Rails.logger).to receive(:error) { |line| errors << line }

      ActiveRecord::Encryption.with_encryption_context(key_provider: other_keys) { deliver(fixture("sticker")) }

      expect(texts).to eq([ FixedReply.not_text("pt-BR") ])
      expect(@event).to have_attributes(status: "processed", payload: nil)
      expect(errors).to include(a_string_including("the chat does not decrypt"))
    end

    it "sends nothing for an update it drops, a service message, or a text that becomes a turn (ProcessTurnJob answers it)" do
      agreed!
      sent.clear

      deliver(variant("text") { |message| message["chat"] = message["chat"].merge("id" => 1) })
      deliver(variant("text") { |message| message.delete("text") && message["pinned_message"] = { "message_id" => 1 } })
      deliver(fixture("text"))

      expect(sent).to be_empty
    end

    it "reads the update all the same when its reply cannot be sent, and logs it by its class" do
      stub_request(:post, bot_api_url("sendMessage")).to_return(bot_api_error(403, "Forbidden: bot was blocked by the user"))
      errors = []
      allow(Rails.logger).to receive(:error) { |line| errors << line }

      outcome = deliver(fixture("start"))

      expect(outcome).to have_attributes(name: :ask)
      expect(@event).to have_attributes(status: "processed", payload: nil)
      expect(errors).to eq([ "telegram fixed reply ask: failed after 1 attempt, Telegram::Client::Error (403)" ])
    end

    # Review finding M3 of pull request #32: a kind of message Telegram adds
    # later is something a person sent, not a service message.
    it "answers a message of a kind it does not know with the line that it reads text here, and counts it" do
      agreed!
      update = variant("text") { |message| message.delete("text") && message["hologram"] = { "file_id" => "x" } }

      expect(deliver(update)).to have_attributes(name: :not_text, reply: FixedReply.not_text("pt-BR"))
      expect(texts.last).to eq(FixedReply.not_text("pt-BR"))
    end
  end

  describe "the stored update" do
    it "is read once: a second job for it does nothing" do
      event = WebhookEvent.record!(update_id: 734_120_102, kind: "message", payload: fixture("text").to_json)
      TelegramUpdateJob.perform_now(event.id)

      expect(Telegram::Inbound).not_to receive(:new)
      TelegramUpdateJob.perform_now(event.id)
    end

    it "names the update by its update_id and what it made in the log, never by anything it held" do
      lines = []
      allow(Rails.logger).to receive(:info) { |line| lines << line }

      deliver(fixture("text"))

      expect(lines).to include("telegram update 734120102: ask")
      expect(lines.join).not_to include("dipirona", sender_id.to_s, "Visitante")
    end

    it "is stripped and marked failed after the last attempt, the line naming the error's class alone (SR-30)" do
      event = WebhookEvent.record!(update_id: 734_120_102, kind: "message", payload: fixture("text").to_json)
      allow_any_instance_of(Telegram::Inbound).to receive(:call).and_raise(ActiveRecord::StatementInvalid, "Failing row contains (Vocês têm dipirona?)")
      errors = []
      allow(Rails.logger).to receive(:error) { |line| errors << line }

      # The error is raised on after the third attempt, for the queue to keep.
      TelegramUpdateJob.perform_later(event.id)
      expect { perform_enqueued_jobs until enqueued_jobs.empty? }.to raise_error(ActiveRecord::StatementInvalid)

      expect(event.reload).to have_attributes(status: "failed", payload: nil, reads: 3)
      expect(errors).to include(match(/telegram update 734120102: given up after 3 attempts, ActiveRecord::StatementInvalid/))
      expect(errors.join).not_to include("dipirona")
    end

    # NFR-03 (M4-4; review findings H1 and H3 of pull request #32, H6 of #33):
    # an update given up got no reply, a silent drop of a message the
    # application had accepted. It gets the fallback's line, in the language a
    # reply would have, unless what it stored answers it.
    describe "given up (NFR-03)" do
      let(:lines) { [] }

      before { allow(Rails.logger).to receive(:error) { |line| lines << line } }

      def read_to_the_end(event)
        TelegramUpdateJob.perform_later(event.id)
        perform_enqueued_jobs(only: TelegramUpdateJob) while enqueued_jobs.any? { |job| job[:job] == TelegramUpdateJob }
      end

      it "sends the person the fallback's line, in the language of the person's app, and strips the update" do
        event = store(variant("text") { |message| message["from"] = message["from"].merge("language_code" => "es") })
        allow_any_instance_of(Telegram::Inbound).to receive(:call).and_raise(ActiveRecord::StatementInvalid)

        expect { read_to_the_end(event) }.to raise_error(ActiveRecord::StatementInvalid)

        expect(event.reload).to have_attributes(status: "failed", payload: nil)
        expect(sent.map { |body| body["text"] }).to eq([ FixedReply.fallback("es") ])
        expect(sent.sole).not_to have_key("reply_markup")
      end

      it "sends a visitor's line in the conversation's language, taking the reply keyboard away" do
        agreed!
        Conversation.sole.update!(language: "en")
        sent.clear
        event = store(fixture("text"))
        allow_any_instance_of(Telegram::Inbound).to receive(:call).and_raise(ActiveRecord::StatementInvalid)

        expect { read_to_the_end(event) }.to raise_error(ActiveRecord::StatementInvalid)

        expect(sent.sole).to include("text" => FixedReply.fallback("en"), "reply_markup" => { "remove_keyboard" => true })
      end

      it "counts a read as it starts, on the update's row" do
        event = store(fixture("text"))
        seen = nil
        allow_any_instance_of(Telegram::Inbound).to receive(:call) do
          seen = WebhookEvent.find(event.id).reads
          raise ActiveRecord::StatementInvalid
        end

        TelegramUpdateJob.perform_now(event.id)

        expect(seen).to eq 1
        expect(event.reload).to have_attributes(status: "received", reads: 1)
      end

      # A killed worker runs no Ruby: no retry, no give-up, and Solid Queue
      # fails the job it held, so the sweep (StrandedSweepJob) is what reads
      # the update again.
      it "gives up at once, reading nothing, an update read three times already, a read that killed its worker among them" do
        event = store(fixture("text"))
        event.update_columns(reads: 3)
        expect_any_instance_of(Telegram::Inbound).not_to receive(:call)

        TelegramUpdateJob.perform_now(event.id)

        expect(event.reload).to have_attributes(status: "failed", payload: nil, reads: 3)
        expect(sent.map { |body| body["text"] }).to eq([ FixedReply.fallback("pt-BR") ])
        expect(lines).to include("telegram update #{event.update_id}: given up after 3 reads")
      end

      it "sends no line for an update whose message it stored, since the message's turn answers it" do
        agreed!
        sent.clear
        event = store(fixture("text"))
        allow_any_instance_of(WebhookEvent).to receive(:strip!).and_wrap_original do |original, status|
          status == "failed" ? original.call(status) : raise(ActiveRecord::ConnectionFailed)
        end

        expect { read_to_the_end(event) }.to raise_error(ActiveRecord::ConnectionFailed)

        expect(event.reload.status).to eq "failed"
        expect(Turn.joins(:inbound_message).where(messages: { webhook_event_id: event.id })).to exist
        expect(sent).to be_empty
      end

      it "sends no line for an update the bot does not answer" do
        event = store(variant("text") { |message| message["chat"] = { "id" => -100_734_120, "title" => "Grupo", "type" => "group" } })
        allow_any_instance_of(Telegram::Inbound).to receive(:call).and_raise(ActiveRecord::StatementInvalid)

        expect { read_to_the_end(event) }.to raise_error(ActiveRecord::StatementInvalid)

        expect(event.reload.status).to eq "failed"
        expect(sent).to be_empty
      end

      # Review finding C5 of pull request #48: the line went before the strip,
      # and nothing marked it sent, so a strip that failed sent it again at the
      # next give-up. The line is read, the update stripped, then the line sent.
      it "sends the line once when the strip fails at first, since it strips before it sends" do
        event = store(fixture("text"))
        event.update_columns(reads: 3)
        strips = 0
        allow_any_instance_of(WebhookEvent).to receive(:strip!).and_wrap_original do |original, status|
          strips += 1
          strips == 1 ? raise(ActiveRecord::QueryCanceled) : original.call(status)
        end

        2.times { TelegramUpdateJob.perform_now(event.id) }

        expect(event.reload).to have_attributes(status: "failed", payload: nil)
        expect(sent.map { |body| body["text"] }).to eq([ FixedReply.fallback("pt-BR") ])
      end

      # The hunter's H6 on pull request #48: the strip decrypted the old payload
      # to compute its change, so an update whose payload no longer decrypts
      # broke each read and then the strip, stayed unread, and NFR-03's sweep
      # took it up every minute until the seven-day purge.
      it "gives up, with no line, and strips an update whose payload no longer decrypts" do
        other_keys = ActiveRecord::Encryption::DerivedSecretKeyProvider.new("another-primary-key-for-the-spec")
        event = ActiveRecord::Encryption.with_encryption_context(key_provider: other_keys) { store(fixture("text")) }

        expect { read_to_the_end(event) }.to raise_error(ActiveRecord::Encryption::Errors::Decryption)

        expect(WebhookEvent.where(id: event.id).pick(:status, :payload, :identity_hash, :reads)).to eq([ "failed", nil, nil, 3 ])
        expect(sent).to be_empty
        expect(lines).to include("telegram update #{event.update_id}: given up, no line: ActiveRecord::Encryption::Errors::Decryption")
      end

      # Review finding C7 and the hunter's H2 of pull request #48, and the
      # close's C2 of M4-6a: the line went, then the drain's error was raised,
      # so the log said the line was not sent and the person's stored replies
      # waited for the sweep. It goes the way a read's line goes.
      it "sends a visitor's line though the stored replies before it break, and tries those again a minute later" do
        agreed!
        visitor = Visitor.sole
        Message.outbound.sole.update_columns(status: "pending", parts_sent: 0)
        sent.clear
        allow(Telegram::Buttons).to receive(:for).and_raise(I18n::MissingTranslationData.new(:pt, "telegram.x"))
        event = store(fixture("text"))
        event.update_columns(reads: 3)

        TelegramUpdateJob.perform_now(event.id)

        expect(sent.map { |body| body["text"] }).to eq([ FixedReply.fallback("pt-BR") ])
        expect(lines).to include("telegram update #{event.update_id}: stored replies not sent, I18n::MissingTranslationData")
        expect(lines.grep(/its line not sent/)).to be_empty
        expect(TelegramReplyJob).to have_been_enqueued.with(visitor.id).at(be_within(1.second).of(1.minute.from_now))
      end

      # The hunter's H4 on pull request #48 (the owner, 2026-11-19: a delete
      # command never gets the fallback's line; the "try again" of one never
      # read stays). A visitor's delete command whose strip failed was read
      # again after its deletion went, as a person the bot holds no row of, and
      # given up with "try again" after "deleted". The deletion strips the
      # update that asked for it.
      it "never reads again, nor gives up, a delete command whose deletion went, so no line follows the confirmation" do
        agreed!
        sent.clear
        event = store(variant("text") { |message| message["text"] = "/apagar" })
        allow_any_instance_of(WebhookEvent).to receive(:strip!).and_raise(ActiveRecord::ConnectionFailed)

        TelegramUpdateJob.perform_later(event.id)
        perform_enqueued_jobs(only: TelegramUpdateJob) # the read stores the turn, and its strip breaks
        perform_enqueued_jobs(only: ProcessTurnJob) # "deleted", then the data goes
        perform_enqueued_jobs(only: TelegramUpdateJob) while enqueued_jobs.any? { |job| job[:job] == TelegramUpdateJob }

        expect(Visitor.count).to eq 0
        expect(WebhookEvent.where(id: event.id).pick(:status, :payload, :identity_hash)).to eq([ "processed", nil, nil ])
        expect(sent.map { |body| body["text"] }).to eq([ FixedReply.telegram_deleted("pt-BR") ])
      end

      it "gives a delete command never read the fallback's line, since the person's data stays and it can be sent again" do
        agreed!
        sent.clear
        event = store(variant("text") { |message| message["text"] = "/apagar" })
        allow_any_instance_of(Telegram::Inbound).to receive(:call).and_raise(ActiveRecord::StatementInvalid)

        expect { read_to_the_end(event) }.to raise_error(ActiveRecord::StatementInvalid)

        expect(Visitor.count).to eq 1
        expect(sent.map { |body| body["text"] }).to eq([ FixedReply.fallback("pt-BR") ])
      end
    end

    # Review finding T2 of pull request #32: the lock kept a person's updates
    # apart but not in order, so a question whose job took the lock before
    # the agreement's got the ask, and two texts could become swapped turns.
    it "reads a person's earlier unread update first, so a question sent after the agreement is a turn" do
      agree = store(variant("agree") { |message| message["message_id"] = 10 })
      question = store(variant("text") { |message| message["message_id"] = 11 })

      outcome = TelegramUpdateJob.perform_now(question.id)

      expect(outcome).to have_attributes(name: :turn)
      expect(agree.reload).to have_attributes(status: "processed", payload: nil)
      expect(Message.inbound.order(:created_at).map(&:body)).to eq([ "Concordo", "Vocês têm dipirona?" ])
      expect(TelegramUpdateJob.perform_now(agree.id)).to be_nil
    end

    it "makes two quick texts turns in the order they were sent, whichever job runs first" do
      agreed!
      first = store(variant("text") { |message| message.merge!("message_id" => 10, "text" => "primeira") })
      second = store(variant("text") { |message| message.merge!("message_id" => 11, "text" => "segunda") })
      first.update_column(:update_id, second.update_id - 1)

      TelegramUpdateJob.perform_now(second.id)

      texts = Turn.joins(:inbound_message).where(messages: { source: "text" }).order(:created_at, :id).map { |turn| turn.inbound_message.body }
      expect(texts).to eq(%w[primeira segunda])
    end

    # Review finding R1 of pull request #32: when the earlier update's read
    # broke, the later one was read first, so a question right after the
    # agreement got the ask. Review finding H6 of pull request #33: the wait
    # spent the later update's own attempts, so a read of its own that broke
    # once was given up. The wait has a budget of its own (WAITS), and the
    # earlier update, read once more at each pass and counted on its row, is
    # given up after its three reads, with its line; then the later is read.
    it "waits for an earlier unread update of the person on a budget of its own, and reads itself once the earlier is given up" do
      agree = store(variant("agree") { |message| message["message_id"] = 10 })
      question = store(variant("text") { |message| message["message_id"] = 11 })
      allow_any_instance_of(Telegram::Inbound).to receive(:call).and_wrap_original do |original, event|
        raise ActiveRecord::ConnectionFailed if event.id == agree.id

        original.call(event)
      end
      allow(Rails.logger).to receive(:error)
      waits = []
      record = ->(event) { waits << event.payload[:job].arguments }

      ActiveSupport::Notifications.subscribed(record, /\Aenqueue(_at)?\.active_job\z/) do
        TelegramUpdateJob.perform_later(question.id)
        3.times do
          perform_enqueued_jobs(only: TelegramUpdateJob) # each pass reads the agreement, which breaks, and waits
          expect(question.reload).to have_attributes(status: "received", reads: 0)
        end
        perform_enqueued_jobs(only: TelegramUpdateJob) # the agreement is given up, then the question is read
      end

      expect(waits).to eq([ [ question.id ], [ question.id, 1 ], [ question.id, 2 ], [ question.id, 3 ] ])
      expect(agree.reload).to have_attributes(status: "failed", payload: nil, reads: 3)
      expect(question.reload).to have_attributes(status: "processed", payload: nil, reads: 1)
      expect(sent.map { |body| body["text"] }).to eq([ FixedReply.fallback("pt-BR"), FixedReply.ask("pt-BR") ])
    end

    # Review finding C1 of pull request #48: the pass over the earlier updates
    # went on past one whose read broke, so a question sent after the
    # agreement was read before it, and got the ask. The pass stops at the
    # first earlier update still unread after its read.
    it "stops the pass over the earlier updates at the first one still unread, so none is read before it" do
      agree = store(variant("agree") { |message| message["message_id"] = 10 })
      first = store(variant("text") { |message| message.merge!("message_id" => 11, "text" => "primeira") })
      second = store(variant("text") { |message| message.merge!("message_id" => 12, "text" => "segunda") })
      broke = false
      allow_any_instance_of(Telegram::Inbound).to receive(:call).and_wrap_original do |original, event|
        if event.id == agree.id && !broke
          broke = true
          raise ActiveRecord::ConnectionFailed
        end
        original.call(event)
      end
      allow(Rails.logger).to receive(:error)

      TelegramUpdateJob.perform_now(second.id)

      expect([ agree, first, second ].map { |event| event.reload.status }).to eq(%w[received received received])
      expect(sent).to be_empty

      perform_enqueued_jobs(only: TelegramUpdateJob) # the wait's pass: the agreement reads now, then the rest in order

      expect(Message.inbound.order(:created_at, :id).map(&:body)).to eq(%w[Concordo primeira segunda])
    end

    it "reads itself after its waits all the same, should the earlier one still be unread" do
      agree = store(variant("agree") { |message| message["message_id"] = 10 })
      question = store(variant("text") { |message| message["message_id"] = 11 })
      allow_any_instance_of(Telegram::Inbound).to receive(:call).and_wrap_original do |original, event|
        raise ActiveRecord::ConnectionFailed if event.id == agree.id

        original.call(event)
      end
      allow_any_instance_of(WebhookEvent).to receive(:strip!).and_wrap_original do |original, status|
        status == "failed" ? raise(ActiveRecord::ConnectionFailed) : original.call(status)
      end
      allow(Rails.logger).to receive(:error)

      TelegramUpdateJob.perform_now(question.id, TelegramUpdateJob::WAITS)

      expect(agree.reload.status).to eq "received"
      expect(question.reload.status).to eq "processed"
    end

    # Review finding M1 of pull request #32.
    it "logs a given-up update before it strips it, so a strip that fails leaves the line" do
      event = WebhookEvent.record!(update_id: 734_120_103, kind: "message", payload: fixture("text").to_json)
      allow_any_instance_of(Telegram::Inbound).to receive(:call).and_raise(ActiveRecord::StatementInvalid)
      allow_any_instance_of(WebhookEvent).to receive(:strip!).and_raise(ActiveRecord::ConnectionFailed)
      errors = []
      allow(Rails.logger).to receive(:error) { |line| errors << line }

      TelegramUpdateJob.perform_later(event.id)
      expect { perform_enqueued_jobs until enqueued_jobs.empty? }.to raise_error(ActiveRecord::StatementInvalid)

      expect(errors).to include("telegram update 734120103: given up after 3 attempts, ActiveRecord::StatementInvalid",
                                "telegram update 734120103: given up, not stripped: ActiveRecord::ConnectionFailed")
    end

    # Review finding H4 of pull request #33: when the database is what failed,
    # the given-up line read the row first, and was lost with that read.
    it "writes the given-up line when the database is what failed, naming the update's row and the job's error" do
      event = store(fixture("text"))
      lines = []
      allow(Rails.logger).to receive(:error) { |line| lines << line }
      allow(WebhookEvent).to receive(:find_by).and_raise(ActiveRecord::ConnectionNotEstablished)

      TelegramUpdateJob.perform_later(event.id)
      expect { perform_enqueued_jobs until enqueued_jobs.empty? }.to raise_error(ActiveRecord::ConnectionNotEstablished)

      expect(lines).to include("telegram update row #{event.id}: given up after 3 attempts, ActiveRecord::ConnectionNotEstablished")
      # Review finding R2 of pull request #33: and that the row was left as it
      # was, its payload still in it.
      expect(lines).to include("telegram update row #{event.id}: given up, not stripped: ActiveRecord::ConnectionNotEstablished")
    end

    it "keeps the sender's hashed identity on an unread update for its order, and drops it once read" do
      event = store(fixture("text"))
      expect(event.identity_hash).to eq(identity)

      TelegramUpdateJob.perform_now(event.id)

      expect(event.reload.identity_hash).to be_nil
    end

    it "reads one person's updates one at a time, under a lock keyed by the hashed identity" do
      allow(AdvisoryLock).to receive(:hold).and_call_original

      deliver(fixture("text"))

      expect(AdvisoryLock).to have_received(:hold).with("telegram:#{identity}")
    end
  end
end
