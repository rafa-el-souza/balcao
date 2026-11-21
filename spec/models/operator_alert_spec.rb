require "rails_helper"

# The operator's alerts through the bot (threat model SR-35, ADR-0020,
# ADR-0022; FR-14's at the cap): each is a row kept until it leaves, keyed by
# its kind and what it is about (NFR-02), sent to the linked chat as plain
# text by the Bot API client, tried three times, and never dropped in silence:
# an alert that cannot leave is a line that names why, never its text or the
# chat (SR-30). An attempt claims the row for a minute, so the job and NFR-03's
# sweep never send it twice at once.
RSpec.describe "SR-35 FR-14 NFR-02 the operator's alert, sent through the bot" do
  include ActiveJob::TestHelper
  include TelegramBotApi

  let(:chat_id) { 734_120_042 }
  let!(:sent) { stub_bot_api }

  def linked! = OperatorChat.link!(OperatorChat.link_url![/\?start=(.+)\z/, 1], chat_id:, language: "pt-BR")

  def alert(**) = OperatorAlert.record!(kind: "budget_cap", key: "2026-11:10.0", text: "Balcão: o teto.", **)

  before { allow(Rails.logger).to receive(:error) }

  it "sends the text to the linked chat, as plain text, and marks it sent" do
    linked!
    row = alert

    row.deliver

    expect(sent).to eq([ { "chat_id" => chat_id, "text" => "Balcão: o teto.", "link_preview_options" => { "is_disabled" => true } } ])
    expect(row.reload).to have_attributes(status: "sent", attempts: 1, sent_at: be_present, next_attempt_at: nil)
  end

  it "sends one marked sent never again" do
    linked!
    row = alert
    row.deliver

    row.deliver
    OperatorAlertJob.perform_now(row.id)

    expect(sent.size).to eq(1)
  end

  it "fails, with a line that names why, when no chat is linked: the alert has nowhere to go" do
    row = alert

    row.deliver

    expect(sent).to be_empty
    expect(row.reload).to have_attributes(status: "failed", error: "unlinked")
    expect(Rails.logger).to have_received(:error).with("operator alert #{row.id} (budget_cap): not sent, no operator chat is linked")
  end

  it "fails at once when Telegram refuses it (the operator blocked the bot), with a line of its code alone" do
    linked!
    stub_request(:post, bot_api_url("sendMessage")).to_return(bot_api_error(403, "Forbidden: bot was blocked by the user"))
    row = alert

    row.deliver

    expect(row.reload).to have_attributes(status: "failed", error: "403")
    expect(Rails.logger).to have_received(:error).with("operator alert #{row.id} (budget_cap): not sent, Telegram refused it (403)")
  end

  it "tries a failure of the way there again by its job, after 3 s and 18 s, and fails it at the third" do
    linked!
    stub_request(:post, bot_api_url("sendMessage")).to_timeout
    row = alert

    travel_to(Time.zone.local(2026, 11, 21, 10, 0)) do
      row.deliver
      expect(row.reload).to have_attributes(status: "pending", attempts: 1, error: "Net::OpenTimeout",
                                            next_attempt_at: Time.zone.local(2026, 11, 21, 10, 0, 3))
      expect(OperatorAlertJob).to have_been_enqueued.with(row.id).at(Time.zone.local(2026, 11, 21, 10, 0, 3))
    end
    travel_to(Time.zone.local(2026, 11, 21, 10, 0, 3)) { row.deliver }
    expect(row.reload).to have_attributes(attempts: 2, next_attempt_at: Time.zone.local(2026, 11, 21, 10, 0, 21))

    travel_to(Time.zone.local(2026, 11, 21, 10, 0, 21)) { row.deliver }

    expect(row.reload).to have_attributes(status: "failed", attempts: 3, error: "Net::OpenTimeout")
    expect(Rails.logger).to have_received(:error)
      .with("operator alert #{row.id} (budget_cap): not sent, the way there failed at each of its 3 attempts (Net::OpenTimeout)")
  end

  it "waits the time a 429 names" do
    linked!
    stub_request(:post, bot_api_url("sendMessage")).to_return(bot_api_error(429, "Too Many Requests: retry after 30", retry_after: 30))
    row = alert

    travel_to(Time.zone.local(2026, 11, 21, 10, 0)) { row.deliver }

    expect(row.reload).to have_attributes(status: "pending", next_attempt_at: Time.zone.local(2026, 11, 21, 10, 0, 30))
  end

  it "leaves an alert waiting for its time alone, and one another attempt holds" do
    linked!
    row = alert
    row.update!(next_attempt_at: 1.minute.from_now)

    row.deliver

    expect(sent).to be_empty
    expect(row.reload).to have_attributes(status: "pending", attempts: 0)
  end

  # A worker that died while it sent leaves the row claimed; NFR-03's sweep
  # takes it up again, and the attempts it spent count.
  it "gives up an alert whose attempts a dying worker spent, at its next claim" do
    linked!
    row = alert
    row.update!(attempts: 3, next_attempt_at: 1.minute.ago)

    row.deliver

    expect(sent).to be_empty
    expect(row.reload).to have_attributes(status: "failed", attempts: 4)
    expect(Rails.logger).to have_received(:error).with("operator alert #{row.id} (budget_cap): not sent, its attempts are spent")
  end

  it "breaks on what is no answer of Telegram's (a local bug), the row left claimed for the sweep" do
    linked!
    allow_any_instance_of(Telegram::Client).to receive(:send_message).and_raise(ArgumentError, "a bug")
    row = alert

    expect { row.deliver }.to raise_error(ArgumentError)

    expect(row.reload).to have_attributes(status: "pending", attempts: 1, next_attempt_at: be > Time.current)
  end

  it "never writes the alert's text or the chat into a line" do
    linked!
    lines = []
    allow(Rails.logger).to receive(:info) { |line| lines << line }
    stub_request(:post, bot_api_url("sendMessage")).to_return(bot_api_error(400, "Bad Request: chat not found"))
    row = alert(text: "Balcão: um texto que não vai para o log.")

    row.deliver

    expect(lines.join).not_to include("um texto", chat_id.to_s)
    expect(Rails.logger).not_to have_received(:error).with(/um texto|#{chat_id}|chat not found/)
  end

  # The read that finds the month paused enqueues the alert's job once the
  # row is committed; a queue that does not take it must not break the turn
  # that read the mode: the row stays pending for NFR-03's sweep, with a line.
  it "leaves the alert to the sweep, with a line, when its job cannot be enqueued" do
    row = alert
    allow(OperatorAlertJob).to receive(:perform_later).and_raise(ActiveRecord::ConnectionNotEstablished, "queue down")

    expect { row.deliver_later }.not_to raise_error

    expect(row.reload.status).to eq("pending")
    expect(Rails.logger).to have_received(:error)
      .with("operator alert #{row.id} (budget_cap): not enqueued, ActiveRecord::ConnectionNotEstablished; the sweep takes it up")
  end

  it "says so too when the queue answers that it did not enqueue the job" do
    row = alert
    allow(OperatorAlertJob).to receive(:perform_later).and_return(false)

    row.deliver_later

    expect(Rails.logger).to have_received(:error).with("operator alert #{row.id} (budget_cap): not enqueued; the sweep takes it up")
  end

  it "sends the runbook's test alert at once, in the linked chat's language" do
    linked!

    row = OperatorAlert.test!

    expect(row).to have_attributes(kind: "test", status: "sent")
    expect(sent.sole["text"]).to eq(I18n.t("operator.test", locale: "pt-BR"))
  end

  describe "its key, the kind and what it is about (NFR-02)" do
    let(:existing) { alert }
    let(:duplicate) { OperatorAlert.new(kind: "budget_cap", key: "2026-11:10.0", text: "outro") }
    let(:call_again) { -> { alert(text: "outro") } }

    it_behaves_like "an idempotency key", index: "index_operator_alerts_on_kind_and_key"
  end
end
