require "rails_helper"
require "rake"

# FR-19: one task of the repository sets the bot from tracked files, inside
# the application's container, where the token already is (SR-38): the
# webhook, the command menu of private chats and the profile (name,
# description, short description), in Portuguese for every language without
# its own, English and Spanish. It reads what the bot has and writes only
# what differs, so running it again changes nothing; the webhook is the
# exception, set at every run, since Telegram never shows the secret back and
# a run after the secret's rotation must register the new one. It ends by
# printing getWebhookInfo, which the runbook's smoke reads.
RSpec.describe "FR-19 SR-06 SR-09 SR-42 the task that sets the bot" do
  let(:client) { instance_double(Telegram::Client) }
  let(:out) { StringIO.new }
  # What Telegram reports after a webhook that took: the four fields the task
  # set (the answer of the demo bot on 2026-11-15 had them all).
  let(:info) do
    { "url" => "#{Rails.configuration.x.public_origin}/webhooks/telegram", "has_custom_certificate" => false, "pending_update_count" => 0,
      "max_connections" => 1, "allowed_updates" => [ "message" ] }
  end
  let(:scope) { { type: "all_private_chats" } }
  let(:privacy) { "#{Rails.configuration.x.public_origin}/privacy" }
  # What Telegram holds, by method and language code; empty until written.
  let(:held) { Hash.new { |hash, key| hash[key] = key.first == :my_commands ? [] : "" } }

  before do
    allow(client).to receive(:set_webhook).and_return(true)
    allow(client).to receive(:webhook_info).and_return(info)
    allow(client).to receive(:my_commands) { |scope:, language_code:| held[[ :my_commands, language_code ]] }
    allow(client).to receive(:set_my_commands) { |commands:, scope:, language_code:| (held[[ :my_commands, language_code ]] = commands.map(&:stringify_keys)) && true }
    { name: :name, description: :description, short_description: :short_description }.each do |field, key|
      allow(client).to receive(:"my_#{field}") { |language_code:| held[[ field, language_code ]] }
      allow(client).to receive(:"set_my_#{field}") { |language_code:, **value| (held[[ field, language_code ]] = value.fetch(key)) && true }
    end
  end

  def setup = Telegram::Setup.new(client:, out:)

  it "registers the public URL, the secret, message updates alone and one connection" do
    setup.call

    expect(client).to have_received(:set_webhook).with(
      url: "#{Rails.configuration.x.public_origin}/webhooks/telegram",
      secret_token: Rails.configuration.x.telegram_webhook_secret,
      allowed_updates: [ "message" ], max_connections: Telegram::Bot::MAX_CONNECTIONS
    )
    # One connection, so updates arrive in the order Telegram numbered them
    # (review finding T2 of pull request #32).
    expect(Telegram::Bot::MAX_CONNECTIONS).to eq 1
  end

  it "writes the command menu of private chats in each language, the delete command last, named as config/commands.yml names them" do
    setup.call

    expect(client).to have_received(:set_my_commands).with(scope:, language_code: "", commands: [
      { command: "reiniciar", description: "começa a conversa de novo" },
      { command: "trace", description: "mostra como eu funciono nesta conversa" },
      { command: "help", description: "o que eu faço e os comandos" },
      { command: "apagar", description: "apaga os seus dados" }
    ])
    expect(held[[ :my_commands, "en" ]].map { |command| command["command"] }).to eq(%w[reset trace help delete])
    expect(held[[ :my_commands, "es" ]].map { |command| command["command"] }).to eq(%w[reiniciar trace help borrar])
  end

  it "writes the profile in each language: a name that says demo, the description the empty chat shows and the short one" do
    setup.call

    expect(held[[ :name, "" ]]).to eq "Balcão (demo)"
    expect(held[[ :description, "" ]]).to include("farmácia fictícia", "Anthropic", "7 dias", "/apagar", "“Concordo”", privacy)
    expect(held[[ :description, "en" ]]).to include("fictional pharmacy", "Anthropic", "7 days", "/delete", "“I agree”", privacy)
    expect(held[[ :description, "es" ]]).to include("farmacia ficticia", "Anthropic", "7 días", "/borrar", "“Acepto”", privacy)
    expect(held[[ :short_description, "es" ]]).to include("ficticia")
  end

  it "keeps every text within Telegram's limits" do
    setup.call

    { name: 64, description: 512, short_description: 120 }.each do |field, limit|
      [ "", "en", "es" ].each { |code| expect(held[[ field, code ]].length).to be_between(1, limit), "#{field} #{code}" }
    end
    held.select { |(method, _), _| method == :my_commands }.each_value do |commands|
      expect(commands).to all(satisfy { |command| command["command"].match?(/\A[a-z0-9_]{1,32}\z/) && command["description"].length.between?(1, 256) })
    end
  end

  it "writes nothing it holds already, and sets the webhook again all the same" do
    setup.call

    setup.call

    # Three languages written by the first run, none by the second.
    %i[set_my_commands set_my_name set_my_description set_my_short_description].each do |writer|
      expect(client).to have_received(writer).exactly(3).times
    end
    expect(client).to have_received(:set_webhook).twice
    expect(out.string.lines.grep(/: (written|unchanged)$/).last(12)).to all(end_with("unchanged\n"))
  end

  it "goes on past a setting Telegram refuses, says which, and answers it" do
    allow(client).to receive(:set_my_name).and_raise(Telegram::Client::Error.new("setMyName: 429 Too Many Requests: retry after 80000",
                                                                                 method_name: "setMyName", code: 429, retry_after: 80_000))

    result = setup.call

    expect(result.failed).to eq([ "name (default)", "name en", "name es" ])
    expect(out.string).to include("name en: not written, setMyName: 429 Too Many Requests: retry after 80000")
    expect(held[[ :description, "en" ]]).to be_present
  end

  it "ends by printing what Telegram holds of the webhook, and never the secret or the token" do
    setup.call

    expect(JSON.parse(out.string[/^getWebhookInfo:\n(.*)\z/m, 1])).to eq(info)
    expect(out.string).not_to include(Rails.configuration.x.telegram_webhook_secret)
    expect(out.string).not_to include(Rails.configuration.x.telegram_bot_token)
  end

  # FR-19 as the owner decided it on 2026-11-15 (the MVP review, rows
  # 32-D-L2 and Q27): the task exits non-zero when what Telegram reports
  # differs from what it set in any of four fields, a field missing from the
  # answer counting as a difference, so a deploy's smoke fails on a webhook
  # that did not take. Telegram never shows the secret back, so no field
  # compares it.
  describe "the webhook Telegram reports, compared with what the task set" do
    it "finds nothing to say when the four fields are what it set" do
      expect(setup.call.differs).to be_empty
      expect(out.string).not_to include("differs")
    end

    {
      "url" => "https://other.example/webhooks/telegram", "allowed_updates" => [ "message", "callback_query" ],
      "max_connections" => 40, "has_custom_certificate" => true
    }.each do |field, value|
      it "names #{field} when Telegram reports another value, and prints both" do
        info[field] = value

        expect(setup.call.differs).to eq([ field ])
        expect(out.string).to include("webhook #{field}: set #{Telegram::Setup.webhook.fetch(field).to_json}, Telegram reports #{value.to_json}")
      end

      it "names #{field} when the answer leaves it out" do
        info.delete(field)

        expect(setup.call.differs).to eq([ field ])
        expect(out.string).to include("webhook #{field}: set #{Telegram::Setup.webhook.fetch(field).to_json}, Telegram reports nothing")
      end
    end
  end

  it "is the rake task telegram:setup, which fails when a setting was not written or the webhook differs" do
    Rails.application.load_tasks if Rake::Task.tasks.none? { |task| task.name == "telegram:setup" }
    setup = instance_double(Telegram::Setup, call: Telegram::Setup::Result.new(info:, failed: [], differs: []))
    allow(Telegram::Setup).to receive(:new).and_return(setup)

    Rake::Task["telegram:setup"].execute
    allow(setup).to receive(:call).and_return(Telegram::Setup::Result.new(info:, failed: [ "name en" ], differs: []))
    expect { Rake::Task["telegram:setup"].execute }.to raise_error(SystemExit)
    allow(setup).to receive(:call).and_return(Telegram::Setup::Result.new(info:, failed: [], differs: [ "max_connections" ]))
    expect { Rake::Task["telegram:setup"].execute }.to raise_error(SystemExit, /max_connections/)
  end

  # The hunter's H4 on pull request #41 (dono, the verifier): the task gave
  # the remedy of a refused write ("run it again later") to a field that
  # differs, which a second run sets the same way and finds the same.
  it "names each failure's own remedy: a later run for a write Telegram refused, the runbook's check for a field that differs" do
    Rails.application.load_tasks if Rake::Task.tasks.none? { |task| task.name == "telegram:setup" }
    setup = instance_double(Telegram::Setup)
    allow(Telegram::Setup).to receive(:new).and_return(setup)
    messages = [ [ [ "name en" ], [] ], [ [], [ "url" ] ] ].map do |failed, differs|
      allow(setup).to receive(:call).and_return(Telegram::Setup::Result.new(info:, failed:, differs:))
      Rake::Task["telegram:setup"].execute
    rescue SystemExit => e
      e.message
    end

    expect(messages.first).to eq("telegram:setup: not written: name en; run it again after the wait Telegram named (the runbook)")
    expect(messages.last).to eq("telegram:setup: the webhook Telegram reports differs in url, which a run again sets the same way; " \
                                "check the values against the runbook's part on the bot before running it again")
  end
end
