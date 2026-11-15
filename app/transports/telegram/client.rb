require "net/http"

module Telegram
  # The one way the application talks to Telegram's Bot API (design §6.6,
  # threat model SR-22): HTTPS to api.telegram.org alone, short timeouts, and a
  # closed list of methods, each a method of this class; nothing else can be
  # called through it. Day 11 brought the two the webhook's registration
  # needs; day 12 the replies' (sendMessage, sendChatAction) and the command
  # menu's and the profile's, each with the get that reads it back (FR-19).
  #
  # Every Bot API URL carries the bot's token, so this class logs nothing and
  # no error of its own names a URL or quotes what a library said: an error is
  # the method, Telegram's code and description, or the failure's class
  # (SR-30), and it keeps no cause, which Rake and anything that prints an
  # error whole would print too (review finding L1 of pull request #32). What
  # it raises as itself (below) is the library's own error, whose message
  # names no URL either: a refused certificate names Telegram's address and
  # OpenSSL's reason (review finding C4 of pull request #47).
  #
  # Only the network's own failures are failures of the way there, each by
  # its name (NETWORK), OpenSSL's error among them unless the certificate was
  # refused: OpenSSL raises that one class for a connection cut during the
  # handshake or the answer too ("unexpected eof while reading"), and only
  # the certificate's check, which calls back with false, tells a
  # certificate that does not prove the host apart (review finding C1 of
  # pull request #47). Anything else is raised as itself, never tried again
  # as the network (review finding H7 of pull request #33): a local bug, the
  # request's body among them, which is built before any connection opens,
  # and a refused certificate. The callers' jobs try those again with their
  # own backoff, and log them by their class (SR-30).
  class Client
    HOST = "api.telegram.org".freeze
    METHODS = %w[
      setWebhook getWebhookInfo sendMessage sendChatAction setMyCommands getMyCommands
      setMyName getMyName setMyDescription getMyDescription setMyShortDescription getMyShortDescription
    ].freeze
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 10
    # A timeout (Net::OpenTimeout, ReadTimeout, WriteTimeout), a name that
    # does not resolve, a call on the socket the system failed (a connection
    # refused, reset, cut or unreachable, Errno's every kind), an answer cut
    # short (EOFError) or that is not HTTP, and OpenSSL's error when no
    # certificate was refused (post).
    NETWORK = [
      Timeout::Error, SocketError, SystemCallError, IOError, Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError,
      OpenSSL::SSL::SSLError
    ].freeze

    # A call that did not answer ok. Telegram's answer has a code: 429 is a
    # wait (rate_limited?, with the seconds it names), any other a refusal
    # (refused?). A failure of the way there (a timeout, a broken connection,
    # an answer that is not Telegram's, and an answer of 5xx whatever its
    # body, FR-19, the owner, 2026-11-15) has none, and names its class or the
    # status.
    class Error < StandardError
      attr_reader :method_name, :code, :retry_after, :failure

      def initialize(message, method_name:, code: nil, retry_after: nil, failure: nil)
        @method_name = method_name
        @code = code
        @retry_after = retry_after
        @failure = failure
        super(message)
      end

      def rate_limited? = code == 429

      def refused? = !code.nil? && !rate_limited?
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

    # sendMessage: a reply to a chat that wrote first, as plain text, with no
    # parse mode, so no markup the model or a visitor wrote becomes a link or
    # a style, and with the link preview disabled, so no page draws its card
    # in the chat (threat model SR-43). A reply keyboard, when one is given,
    # is the agreement's button or its removal (FR-19).
    def send_message(chat_id:, text:, reply_markup: nil)
      call("sendMessage", { chat_id:, text:, link_preview_options: { is_disabled: true }, reply_markup: }.compact)
    end

    # sendChatAction: the typing status, which Telegram clears after five
    # seconds or when a message arrives (FR-19, NFR-03).
    def send_chat_action(chat_id:, action: "typing") = call("sendChatAction", chat_id:, action:)

    # The command menu of a scope and a language (setMyCommands, getMyCommands).
    def set_my_commands(commands:, scope:, language_code:) = call("setMyCommands", commands:, scope:, language_code:)

    def my_commands(scope:, language_code:) = call("getMyCommands", scope:, language_code:)

    # The profile, by language: the name, the description an empty chat
    # shows and the short description of the profile page and of a share.
    def set_my_name(name:, language_code:) = call("setMyName", name:, language_code:)

    def my_name(language_code:) = call("getMyName", language_code:).fetch("name")

    def set_my_description(description:, language_code:) = call("setMyDescription", description:, language_code:)

    def my_description(language_code:) = call("getMyDescription", language_code:).fetch("description")

    def set_my_short_description(short_description:, language_code:)
      call("setMyShortDescription", short_description:, language_code:)
    end

    def my_short_description(language_code:) = call("getMyShortDescription", language_code:).fetch("short_description")

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
      body = params.to_json
      refused = false
      http = Net::HTTP.new(HOST, 443)
      http.use_ssl = true
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT
      http.write_timeout = READ_TIMEOUT
      # OpenSSL calls it for each certificate of the chain, the host's name
      # checked on the last; it notes a refusal and changes no answer.
      http.verify_callback = lambda do |verified, _store|
        refused ||= !verified
        verified
      end
      begin
        http.start { |session| session.post("/bot#{@token}/#{method}", body, "content-type" => "application/json") }
      rescue *NETWORK => e
        raise if refused

        raise Error.new("#{method}: #{e.class}", method_name: method, failure: e.class.name), cause: nil
      end
    end

    # Telegram answers JSON with "ok", whatever the HTTP status; an answer of
    # 5xx, its JSON or a proxy's page, and anything else are failures of the
    # way there, tried again like a timeout (FR-19; review finding H3 of pull
    # request #33: a 5xx in Telegram's JSON was a refusal, failed at once).
    def answer(method, response)
      raise Error.new("#{method}: HTTP #{response.code}", method_name: method, failure: "HTTP #{response.code}") if response.code.to_i >= 500

      body = JSON.parse(response.body.to_s)
      return body if body.is_a?(Hash) && body.key?("ok")

      raise Error.new("#{method}: HTTP #{response.code}", method_name: method, failure: "HTTP #{response.code}")
    rescue JSON::ParserError
      raise Error.new("#{method}: HTTP #{response.code}, not JSON", method_name: method, failure: "HTTP #{response.code}"), cause: nil
    end
  end
end
