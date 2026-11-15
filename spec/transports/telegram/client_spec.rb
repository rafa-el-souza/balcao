require "rails_helper"

# The Bot API client (design §6.6, threat model SR-22): one host, HTTPS, short
# timeouts, and a closed list of methods, begun on day 11 with the two the
# webhook's registration needs. Every Bot API URL carries the bot's token, so
# no error and no line names a URL (SR-30).
RSpec.describe "SR-22 FR-19 the Telegram Bot API client" do
  let(:token) { "123456789:AAtest-token_for-the-client" }
  let(:client) { Telegram::Client.new(token:) }
  let(:base) { "https://api.telegram.org/bot#{token}" }

  def answer(result) = { status: 200, body: { ok: true, result: }.to_json, headers: { "content-type" => "application/json" } }

  it "exposes the methods of its closed list and no way to call another" do
    expect(Telegram::Client::METHODS).to eq(%w[
      setWebhook getWebhookInfo sendMessage sendChatAction setMyCommands getMyCommands
      setMyName getMyName setMyDescription getMyDescription setMyShortDescription getMyShortDescription
    ])
    expect(Telegram::Client.public_instance_methods(false)).to contain_exactly(
      :set_webhook, :webhook_info, :send_message, :send_chat_action, :set_my_commands, :my_commands,
      :set_my_name, :my_name, :set_my_description, :my_description, :set_my_short_description, :my_short_description
    )
    expect { client.send(:call, "getUpdates") }.to raise_error(ArgumentError, /getUpdates/)
  end

  # Threat model SR-43: plain text, whatever the text holds, and no preview.
  describe "sendMessage (FR-19, SR-43)" do
    it "sends the text as plain text, with no parse mode and the link preview disabled" do
      text = "**Dipirona** <a href=\"https://evil.example\">aqui</a> [link](https://evil.example)"
      stub = stub_request(:post, "#{base}/sendMessage")
             .with(body: { chat_id: 7_341_200_001, text:, link_preview_options: { is_disabled: true } }.to_json)
             .to_return(answer({ message_id: 12 }))

      expect(client.send_message(chat_id: 7_341_200_001, text:)).to eq("message_id" => 12)
      expect(stub).to have_been_requested.once
    end

    it "carries a reply keyboard when given one, and still no parse mode" do
      keyboard = { keyboard: [ [ { text: "Concordo" } ] ], resize_keyboard: true }
      stub = stub_request(:post, "#{base}/sendMessage")
             .with { |request| JSON.parse(request.body) == JSON.parse({ chat_id: 1, text: "Oi", link_preview_options: { is_disabled: true }, reply_markup: keyboard }.to_json) }
             .to_return(answer({ message_id: 13 }))

      client.send_message(chat_id: 1, text: "Oi", reply_markup: keyboard)

      expect(stub).to have_been_requested.once
    end
  end

  it "shows the typing status in a chat (FR-19, NFR-03)" do
    stub = stub_request(:post, "#{base}/sendChatAction").with(body: { chat_id: 5, action: "typing" }.to_json).to_return(answer(true))

    expect(client.send_chat_action(chat_id: 5)).to be(true)
    expect(stub).to have_been_requested.once
  end

  describe "the bot's command menu and profile, read and written by language (FR-19)" do
    let(:scope) { { type: "all_private_chats" } }

    it "reads and writes the command menu of private chats" do
      commands = [ { command: "reiniciar", description: "começa de novo" } ]
      read = stub_request(:post, "#{base}/getMyCommands").with(body: { scope:, language_code: "en" }.to_json)
                                                         .to_return(answer([ { command: "reset", description: "starts over" } ]))
      write = stub_request(:post, "#{base}/setMyCommands").with(body: { commands:, scope:, language_code: "" }.to_json).to_return(answer(true))

      expect(client.my_commands(scope:, language_code: "en")).to eq([ { "command" => "reset", "description" => "starts over" } ])
      expect(client.set_my_commands(commands:, scope:, language_code: "")).to be(true)
      expect([ read, write ]).to all(have_been_requested.once)
    end

    {
      [ :my_name, :set_my_name, "getMyName", "setMyName", "name" ] => "Balcão (demo)",
      [ :my_description, :set_my_description, "getMyDescription", "setMyDescription", "description" ] => "Uma demonstração.",
      [ :my_short_description, :set_my_short_description, "getMyShortDescription", "setMyShortDescription", "short_description" ] => "Demo."
    }.each do |(reader, writer, get, set, field), value|
      it "reads and writes #{field}, by its language code" do
        read = stub_request(:post, "#{base}/#{get}").with(body: { language_code: "es" }.to_json).to_return(answer({ field => value }))
        write = stub_request(:post, "#{base}/#{set}").with(body: { field => value, language_code: "es" }.to_json).to_return(answer(true))

        expect(client.public_send(reader, language_code: "es")).to eq(value)
        expect(client.public_send(writer, field.to_sym => value, language_code: "es")).to be(true)
        expect([ read, write ]).to all(have_been_requested.once)
      end
    end
  end

  it "registers the webhook with its URL, its secret, the kinds of update and the connections, over HTTPS to api.telegram.org" do
    stub = stub_request(:post, "#{base}/setWebhook")
           .with(body: { url: "https://demo.example/webhooks/telegram", secret_token: "s3cret_-x",
                         allowed_updates: [ "message" ], max_connections: 3 }.to_json,
                 headers: { "Content-Type" => "application/json" })
           .to_return(answer(true))

    result = client.set_webhook(url: "https://demo.example/webhooks/telegram", secret_token: "s3cret_-x",
                                allowed_updates: [ "message" ], max_connections: 3)

    expect(result).to be(true)
    expect(stub).to have_been_requested.once
  end

  it "reads what Telegram holds of the webhook" do
    stub_request(:post, "#{base}/getWebhookInfo").to_return(answer({ url: "", pending_update_count: 0 }))

    expect(client.webhook_info).to eq("url" => "", "pending_update_count" => 0)
  end

  it "sets its timeouts, so a call never holds the task or a job for long" do
    expect(Telegram::Client::OPEN_TIMEOUT).to be <= 5
    expect(Telegram::Client::READ_TIMEOUT).to be <= 10
    http = Net::HTTP.new("api.telegram.org", 443)
    allow(Net::HTTP).to receive(:new).and_return(http)
    stub_request(:post, "#{base}/getWebhookInfo").to_return(answer({}))

    client.webhook_info

    expect([ http.use_ssl?, http.open_timeout, http.read_timeout, http.write_timeout ])
      .to eq([ true, Telegram::Client::OPEN_TIMEOUT, Telegram::Client::READ_TIMEOUT, Telegram::Client::READ_TIMEOUT ])
  end

  describe "a call that fails says which method and why, never the token" do
    it "on Telegram's refusal, with its code, its description and the wait a 429 names" do
      stub_request(:post, "#{base}/setWebhook").to_return(
        status: 429, body: { ok: false, error_code: 429, description: "Too Many Requests: retry after 7", parameters: { retry_after: 7 } }.to_json
      )

      expect { client.set_webhook(url: "u", secret_token: "s", allowed_updates: [], max_connections: 1) }
        .to raise_error(Telegram::Client::Error) { |error|
          expect(error).to have_attributes(method_name: "setWebhook", code: 429, retry_after: 7)
          expect(error).to be_rate_limited
          expect(error).not_to be_refused
          expect(error.message).to include("setWebhook", "429", "Too Many Requests")
          expect(error.message).not_to include(token)
        }
    end

    it "tells a refusal (any other answer that is not ok) from a wait and from a failure of the way there" do
      stub_request(:post, "#{base}/sendMessage").to_return(
        status: 403, body: { ok: false, error_code: 403, description: "Forbidden: bot was blocked by the user" }.to_json
      )

      expect { client.send_message(chat_id: 1, text: "Oi") }.to raise_error(Telegram::Client::Error) { |error|
        expect(error).to have_attributes(code: 403, retry_after: nil, failure: nil)
        expect(error).to be_refused
        expect(error).not_to be_rate_limited
      }
    end

    # FR-19 as the owner decided it on 2026-11-15 (the MVP review, rows
    # 33-H3 and Q29): a 5xx in Telegram's own JSON was a refusal, failed at
    # once, while the same status on a proxy's page was tried again.
    it "takes an answer of 5xx as a failure of the way there, whatever its body" do
      [ 500, 502, 503 ].each do |status|
        stub_request(:post, "#{base}/sendMessage").to_return(
          status:, body: { ok: false, error_code: status, description: "Internal Server Error" }.to_json
        )

        expect { client.send_message(chat_id: 1, text: "Oi") }.to raise_error(Telegram::Client::Error) { |error|
          expect(error).to have_attributes(code: nil, failure: "HTTP #{status}", retry_after: nil)
          expect(error).not_to be_refused
          expect(error).not_to be_rate_limited
          expect(error.message).to eq("sendMessage: HTTP #{status}")
        }
      end
    end

    # Review finding L1 of pull request #32: Rake, and anything that prints
    # an error whole, prints its causes too, and a library's message may
    # carry what this class keeps out of its own.
    it "keeps the library's error out of its cause, and names its class instead" do
      stub_request(:post, "#{base}/getWebhookInfo").to_raise(SocketError.new("getaddrinfo: #{token}"))

      expect { client.webhook_info }.to raise_error(Telegram::Client::Error) { |error|
        expect(error.cause).to be_nil
        expect(error).to have_attributes(code: nil, failure: "SocketError")
        expect(error).not_to be_refused
        expect(error).not_to be_rate_limited
      }
    end

    it "on a timeout, a broken connection or an answer that is not JSON, by the error's class" do
      [ -> { stub_request(:post, "#{base}/getWebhookInfo").to_timeout },
        -> { stub_request(:post, "#{base}/getWebhookInfo").to_raise(SocketError.new("getaddrinfo: #{token}")) },
        -> { stub_request(:post, "#{base}/getWebhookInfo").to_return(status: 502, body: "<html>#{token}</html>") } ].each do |failure|
        WebMock.reset!
        failure.call

        expect { client.webhook_info }.to raise_error(Telegram::Client::Error) { |error|
          expect(error.message).to start_with("getWebhookInfo")
          expect(error.message).not_to include(token)
          expect(error.code).to be_nil
        }
      end
    end
  end
end
