require "rails_helper"
require "rake"

# FR-19: one task of the repository registers the bot's webhook, from tracked
# values, inside the application's container, where the token already is
# (SR-38), and ends by printing getWebhookInfo, which the runbook's smoke
# reads. Telegram never shows the secret back, so the webhook is set at every
# run: a run after the secret's rotation registers the new one, and a run
# with nothing changed leaves the webhook as it was.
RSpec.describe "FR-19 SR-06 SR-09 SR-42 the task that registers the bot's webhook" do
  let(:client) { instance_double(Telegram::Client) }
  let(:out) { StringIO.new }
  let(:info) { { "url" => "https://demo.example/webhooks/telegram", "pending_update_count" => 0, "max_connections" => 3, "allowed_updates" => [ "message" ] } }

  before do
    allow(client).to receive(:set_webhook).and_return(true)
    allow(client).to receive(:webhook_info).and_return(info)
  end

  it "registers the public URL, the secret, message updates alone and few connections, then prints what Telegram holds" do
    Telegram::Setup.new(client:, out:).call

    expect(client).to have_received(:set_webhook).with(
      url: "#{Rails.configuration.x.public_origin}/webhooks/telegram",
      secret_token: Rails.configuration.x.telegram_webhook_secret,
      allowed_updates: [ "message" ], max_connections: Telegram::Bot::MAX_CONNECTIONS
    )
    expect(Telegram::Bot::MAX_CONNECTIONS).to be <= 5
    expect(JSON.parse(out.string)).to eq(info)
  end

  it "never prints the secret or the token" do
    Telegram::Setup.new(client:, out:).call

    expect(out.string).not_to include(Rails.configuration.x.telegram_webhook_secret)
    expect(out.string).not_to include(Rails.configuration.x.telegram_bot_token)
  end

  it "is the rake task telegram:setup" do
    Rails.application.load_tasks if Rake::Task.tasks.none? { |task| task.name == "telegram:setup" }
    setup = instance_double(Telegram::Setup, call: info)
    allow(Telegram::Setup).to receive(:new).and_return(setup)

    Rake::Task["telegram:setup"].execute

    expect(setup).to have_received(:call)
  end
end
