require "rails_helper"

# FR-19's inbound side at the edge (threat model SR-06, SR-07, SR-09): the
# secret header compared in constant time before the body is read; an
# authenticated update stored keyed by its update_id and answered 200
# whatever it holds, for TelegramUpdateJob to read; nothing parsed, stored or
# enqueued for a request without the secret.
RSpec.describe "FR-19 SR-06 SR-07 SR-09 POST /webhooks/telegram", type: :request do
  include ActiveJob::TestHelper

  let(:secret) { Rails.configuration.x.telegram_webhook_secret }
  let(:update) { { update_id: 734_120_001, message: { message_id: 7, text: "Vocês têm dipirona?" } } }

  def deliver(body, secret: self.secret)
    headers = { "Content-Type" => "application/json" }
    headers["X-Telegram-Bot-Api-Secret-Token"] = secret if secret
    post "/webhooks/telegram", params: body.is_a?(String) ? body : body.to_json, headers:
  end

  it "stores an authenticated update keyed by its update_id, with its kind, enqueues its reading and answers 200" do
    deliver(update)

    expect(response).to have_http_status(:ok)
    event = WebhookEvent.sole
    expect(event).to have_attributes(update_id: 734_120_001, kind: "message", status: "received")
    expect(event.update_hash).to eq(update.deep_stringify_keys)
    expect(TelegramUpdateJob).to have_been_enqueued.with(event.id)
  end

  it "compares the secret in constant time" do
    allow(ActiveSupport::SecurityUtils).to receive(:secure_compare).and_call_original

    deliver(update)

    expect(ActiveSupport::SecurityUtils).to have_received(:secure_compare).with(secret, secret)
  end

  describe "without the secret (SR-06)" do
    [ nil, "", "wrong-secret", "#{Rails.configuration.x.telegram_webhook_secret}x" ].each do |sent|
      it "answers 401 to #{sent.inspect} and stores, enqueues and parses nothing" do
        expect(JSON).not_to receive(:parse)

        deliver(update, secret: sent)

        expect(response).to have_http_status(:unauthorized)
        expect(response.body).to be_empty
        expect(WebhookEvent.count).to eq(0)
        expect(enqueued_jobs).to be_empty
      end
    end

    it "counts the refusals and says so in the log above ten a minute, never with what was sent" do
      store = Rack::Attack.cache.store
      Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
      logged = []
      allow(Rails.logger).to receive(:warn) { |line| logged << [ :warn, line ] }
      allow(Rails.logger).to receive(:error) { |line| logged << [ :error, line ] }

      travel_to(Time.zone.local(2026, 11, 14, 15, 0)) do
        11.times { deliver(update, secret: "forged-#{SecureRandom.hex(4)}") }
      end

      expect(logged.count { |level, _| level == :warn }).to eq(11)
      expect(logged.select { |level, _| level == :error }.map(&:last)).to contain_exactly(match(/more than 10.*minute.*SR-06/))
      expect(logged.map(&:last).join).not_to include("forged", "dipirona")
    ensure
      Rack::Attack.cache.store = store
    end
  end

  # SR-07: Telegram sends an update again until it gets its 200.
  it "takes a redelivered update as a no-op once it was read" do
    deliver(update)
    WebhookEvent.sole.strip!("processed")
    clear_enqueued_jobs

    deliver(update)

    expect(response).to have_http_status(:ok)
    expect(WebhookEvent.count).to eq(1)
    expect(enqueued_jobs).to be_empty
  end

  it "enqueues the reading again for a redelivered update still unread, as when the first enqueue failed" do
    # Production answers the error 500, and Telegram sends the update again.
    allow(TelegramUpdateJob).to receive(:perform_later).and_raise(ActiveRecord::ConnectionNotEstablished)
    expect { deliver(update) }.to raise_error(ActiveRecord::ConnectionNotEstablished)
    allow(TelegramUpdateJob).to receive(:perform_later).and_call_original

    deliver(update)

    expect(response).to have_http_status(:ok)
    expect(WebhookEvent.count).to eq(1)
    expect(TelegramUpdateJob).to have_been_enqueued.with(WebhookEvent.sole.id)
  end

  # SR-09: an update the application cannot use is answered 200 all the same,
  # so Telegram never sends it again; the job drops it (SR-42).
  it "stores and answers 200 an update of a kind the bot does not use" do
    deliver({ update_id: 734_120_002, edited_message: { message_id: 7, text: "Vocês têm dipirona 500 mg?" } })

    expect(response).to have_http_status(:ok)
    expect(WebhookEvent.sole).to have_attributes(update_id: 734_120_002, kind: "edited_message")
  end

  { "not JSON" => "not json", "a JSON list" => "[]", "no update_id" => { message: {} },
    "an update_id that is not a number" => { update_id: "7", message: {} }, "an empty body" => "" }.each do |label, body|
    it "answers 200 to an authenticated body that is not an update (#{label}), storing nothing, and counts it" do
      allow(Rails.logger).to receive(:warn)

      deliver(body)

      expect(response).to have_http_status(:ok)
      expect(WebhookEvent.count).to eq(0)
      expect(enqueued_jobs).to be_empty
      expect(Rails.logger).to have_received(:warn).with(/not an update/)
    end
  end

  it "names an update of no kind it knows as unknown" do
    deliver({ update_id: 734_120_003, "Weird-Kind": {} })

    expect(WebhookEvent.sole.kind).to eq("unknown")
  end

  it "takes no format extension, so the endpoint has one path" do
    post "/webhooks/telegram.json", params: update.to_json,
                                    headers: { "Content-Type" => "application/json", "X-Telegram-Bot-Api-Secret-Token" => secret }

    expect(response).to have_http_status(:not_found)
  end
end
