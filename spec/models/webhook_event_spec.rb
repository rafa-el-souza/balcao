require "rails_helper"

RSpec.describe "NFR-02 SR-07 FR-19 webhook event, keyed by the SHA-256 of its raw body" do
  def status_body(status)
    { "object" => "whatsapp_business_account",
      "entry" => [ { "changes" => [ { "value" => { "statuses" => [ { "id" => "wamid.OUT1", "status" => status } ] } } ] } ] }.to_json
  end

  let(:raw_body) { status_body("delivered") }

  it "stores a new event as received, with the parsed payload" do
    event = WebhookEvent.record!(raw_body:)

    expect(event).to be_previously_new_record
    expect(event).to have_attributes(body_sha256: Digest::SHA256.hexdigest(raw_body),
                                     payload: JSON.parse(raw_body), status: "received")
    expect(event.received_at).to be_present
  end

  # Review finding C3 of pull request #7: Meta's sent, delivered and read
  # notifications for one outbound message carry the same message id, so a
  # key made of that id kept only the first of them.
  it "stores each status notification of one message as its own event" do
    events = %w[sent delivered read].map { |status| WebhookEvent.record!(raw_body: status_body(status)) }

    expect(events).to all(be_previously_new_record)
    expect(WebhookEvent.count).to eq(3)
  end

  it "parses nothing it cannot store: a body that is not JSON raises before any insert" do
    expect { WebhookEvent.record!(raw_body: "not json") }.to raise_error(JSON::ParserError)
    expect(WebhookEvent.count).to eq(0)
  end

  it_behaves_like "an idempotency key", index: "index_webhook_events_on_body_sha256" do
    let(:existing) { WebhookEvent.record!(raw_body:) }
    let(:duplicate) { build(:webhook_event, body_sha256: Digest::SHA256.hexdigest(raw_body)) }
    let(:call_again) { -> { WebhookEvent.record!(raw_body:) } }
  end
end
