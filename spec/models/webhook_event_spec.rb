require "rails_helper"

RSpec.describe "NFR-02 SR-07 webhook event, keyed by the Meta message id" do
  let(:payload) { { "object" => "whatsapp_business_account", "entry" => [ { "id" => "1" } ] } }

  it "stores a new event as received" do
    event = WebhookEvent.record!(external_id: "wamid.NEW", payload:)

    expect(event).to be_previously_new_record
    expect(event).to have_attributes(external_id: "wamid.NEW", payload:, status: "received")
    expect(event.received_at).to be_present
  end

  it_behaves_like "an idempotency key", index: "index_webhook_events_on_external_id" do
    let(:existing) { create(:webhook_event, external_id: "wamid.REDELIVERED") }
    let(:duplicate) { build(:webhook_event, external_id: "wamid.REDELIVERED") }
    let(:call_again) { -> { WebhookEvent.record!(external_id: "wamid.REDELIVERED", payload:) } }
  end
end
