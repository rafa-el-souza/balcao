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

  RECORDED = %w[start text agree help photo sticker voice].freeze

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
    event = WebhookEvent.record!(update_id: update["update_id"], kind:, payload: update.to_json)
    outcome = TelegramUpdateJob.perform_now(event.id)
    @event = event.reload
    outcome
  end

  let(:sender_id) { fixture("text").dig("message", "from", "id") }
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
      expect(deleted).to have_attributes(name: :deleted, reply: FixedReply.command(:delete, "pt-BR"))
      stored_nothing
    end

    it "takes no caption for an agreement: a photo captioned with the phrase gets the ask" do
      update = variant("photo") { |message| message["caption"] = "Concordo" }

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

      expect(outcome).to have_attributes(name: :agreed, reply: FixedReply.greeting("pt-BR"), language: "pt-BR")
      visitor = Visitor.sole
      expect(visitor).to have_attributes(channel: "telegram", identity_hash: identity, telegram_chat_id: sender_id.to_s, agreed_at: at)
      conversation = Conversation.sole
      expect(conversation).to have_attributes(visitor:, language: "pt-BR")
      inbound, outbound = conversation.messages.order(:created_at, :direction).partition(&:inbound?).map(&:sole)
      expect(inbound).to have_attributes(body: "Concordo", source: "command", channel: "telegram",
                                         external_id: "#{visitor.id}:3", webhook_event_id: @event.id)
      expect(outbound).to have_attributes(body: FixedReply.greeting("pt-BR"), status: "pending")
      expect(Turn.sole).to have_attributes(state: "replied", inbound_message: inbound)
      expect(TraceEvent.sole.span_attributes).to eq("balcao.command.name" => "agree")
      expect(enqueued_jobs.map { |job| job["job_class"] }).not_to include("ProcessTurnJob")
    end

    it "starts the first conversation in English for an English app, and the greeting follows" do
      update = variant("agree") do |message|
        message["text"] = "I agree"
        message["from"] = message["from"].merge("language_code" => "en")
      end

      expect(deliver(update)).to have_attributes(name: :agreed, reply: FixedReply.greeting("en"), language: "en")
      expect(Conversation.sole.language).to eq("en")
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
        expect(a_request(:any, /telegram/)).not_to have_been_made
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

      expect(event.reload).to have_attributes(status: "failed", payload: nil)
      expect(errors).to include(match(/telegram update 734120102: given up after 3 attempts, ActiveRecord::StatementInvalid/))
      expect(errors.join).not_to include("dipirona")
    end

    it "reads one person's updates one at a time, under a lock keyed by the hashed identity" do
      allow(AdvisoryLock).to receive(:hold).and_call_original

      deliver(fixture("text"))

      expect(AdvisoryLock).to have_received(:hold).with("telegram:#{identity}")
    end
  end
end
