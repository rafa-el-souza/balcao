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
    expect(Telegram::Client::METHODS).to eq(%w[setWebhook getWebhookInfo])
    expect(Telegram::Client.public_instance_methods(false)).to contain_exactly(:set_webhook, :webhook_info)
    expect { client.send(:call, "getUpdates") }.to raise_error(ArgumentError, /getUpdates/)
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
          expect(error.message).to include("setWebhook", "429", "Too Many Requests")
          expect(error.message).not_to include(token)
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
