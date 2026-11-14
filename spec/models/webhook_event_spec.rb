require "rails_helper"

RSpec.describe "NFR-02 SR-07 FR-19 a stored Telegram update, keyed by its update_id" do
  let(:raw) { { update_id: 734_120_001, message: { message_id: 7, text: "Vocês têm dipirona?" } }.to_json }

  it "stores a new update as received, with its kind and its body" do
    event = WebhookEvent.record!(update_id: 734_120_001, kind: "message", payload: raw)

    expect(event).to be_previously_new_record
    expect(event).to have_attributes(update_id: 734_120_001, kind: "message", payload: raw, status: "received")
    expect(event.received_at).to be_present
    expect(event.update_hash).to eq(JSON.parse(raw))
  end

  # Telegram sends an update again until it is answered 200, and keeps one
  # for 24 hours: the second copy meets the unique index and changes nothing.
  it "takes a redelivered update as the one already stored, as it was stored" do
    first = WebhookEvent.record!(update_id: 734_120_001, kind: "message", payload: raw)
    first.strip!("processed")

    again = WebhookEvent.record!(update_id: 734_120_001, kind: "message", payload: raw)

    expect(again).to eq(first)
    expect(again).not_to be_previously_new_record
    expect(again.reload).to have_attributes(payload: nil, status: "processed")
  end

  # Threat model SR-41: what a visitor sends is encrypted at rest.
  it "keeps the body encrypted in the database (SR-41)" do
    event = WebhookEvent.record!(update_id: 734_120_001, kind: "message", payload: raw)

    stored = WebhookEvent.connection.select_value(
      WebhookEvent.sanitize_sql([ "SELECT payload FROM webhook_events WHERE id = ?", event.id ])
    )
    expect(stored).not_to include("dipirona")
    expect(stored).not_to include("734120001")
    expect(WebhookEvent.find(event.id).payload).to eq(raw)
  end

  # Review finding RN3 of pull request #7, in its Telegram form (design §10,
  # note of 2026-11-14): once read, the update keeps its id and its kind, and
  # nothing of the person or of what they wrote, no digest included.
  it "keeps only its update_id and its kind once read (SR-10)" do
    event = WebhookEvent.record!(update_id: 734_120_001, kind: "message", payload: raw)

    event.strip!("ignored")

    expect(event.reload).to have_attributes(update_id: 734_120_001, kind: "message", payload: nil, status: "ignored")
    expect(event.update_hash).to be_nil
    row = WebhookEvent.connection.select_one(WebhookEvent.sanitize_sql([ "SELECT * FROM webhook_events WHERE id = ?", event.id ]))
    expect(row.keys).to match_array(%w[id update_id kind payload status received_at created_at updated_at])
  end

  it "takes a kind Telegram names, and refuses anything else" do
    expect(build(:webhook_event, kind: "edited_message")).to be_valid
    [ "", "Message", "x" * 65, "message; drop" ].each do |kind|
      expect(build(:webhook_event, kind:)).not_to be_valid
    end
  end

  it_behaves_like "an idempotency key", index: "index_webhook_events_on_update_id" do
    let(:existing) { WebhookEvent.record!(update_id: 734_120_001, kind: "message", payload: raw) }
    let(:duplicate) { build(:webhook_event, update_id: 734_120_001) }
    let(:call_again) { -> { WebhookEvent.record!(update_id: 734_120_001, kind: "message", payload: raw) } }
  end
end
