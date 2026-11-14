require "net/http"

module Telegram
  # The one way the application talks to Telegram's Bot API (design §6.6,
  # threat model SR-22): HTTPS to api.telegram.org alone, short timeouts, and a
  # closed list of methods, each a method of this class; nothing else can be
  # called through it. Day 11 brought the two the webhook's registration needs;
  # day 12 adds the replies' (sendMessage, sendChatAction) and the profile's.
  #
  # Every Bot API URL carries the bot's token, so this class logs nothing and
  # no error it raises names a URL or quotes what a library said: an error is
  # the method, Telegram's code and description, or the failure's class (SR-30).
  class Client
    HOST = "api.telegram.org".freeze
    METHODS = %w[setWebhook getWebhookInfo].freeze
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 10

    class Error < StandardError
      attr_reader :method_name, :code, :retry_after

      def initialize(message, method_name:, code: nil, retry_after: nil)
        @method_name = method_name
        @code = code
        @retry_after = retry_after
        super(message)
      end
    end

    def initialize(token: Rails.configuration.x.telegram_bot_token)
      @token = token
    end

    # setWebhook: where Telegram posts the updates, the secret it sends with
    # each (SR-06), the kinds it sends (SR-42) and how many at a time (SR-09).
    def set_webhook(url:, secret_token:, allowed_updates:, max_connections:)
      call("setWebhook", url:, secret_token:, allowed_updates:, max_connections:)
    end

    # getWebhookInfo: what Telegram holds of the webhook, the secret aside.
    def webhook_info = call("getWebhookInfo")

    private

    def call(method, params = {})
      raise ArgumentError, "#{method} is not among the Bot API methods the application calls (design §6.6)" unless METHODS.include?(method)

      body = answer(method, post(method, params))
      return body["result"] if body["ok"] == true

      code = body["error_code"]
      raise Error.new("#{method}: #{code} #{body["description"]}".strip, method_name: method, code:,
                                                                         retry_after: body.dig("parameters", "retry_after"))
    end

    def post(method, params)
      http = Net::HTTP.new(HOST, 443)
      http.use_ssl = true
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT
      http.write_timeout = READ_TIMEOUT
      http.start { |session| session.post("/bot#{@token}/#{method}", params.to_json, "content-type" => "application/json") }
    rescue StandardError => e
      raise Error.new("#{method}: #{e.class}", method_name: method)
    end

    # Telegram answers JSON with "ok", whatever the HTTP status; anything else
    # is a failure of the way there.
    def answer(method, response)
      body = JSON.parse(response.body.to_s)
      return body if body.is_a?(Hash) && body.key?("ok")

      raise Error.new("#{method}: HTTP #{response.code}", method_name: method)
    rescue JSON::ParserError
      raise Error.new("#{method}: HTTP #{response.code}, not JSON", method_name: method)
    end
  end
end
