module Telegram
  # POST /webhooks/telegram (FR-19, design §6.6), the Telegram bot's inbound
  # edge. A Rack endpoint, not a controller: Rails' controller instrumentation
  # reads a request's parameters before any action, so a form or multipart
  # body would be parsed, written to tempfiles and logged before the secret
  # was checked (review finding T3 of pull request #32). Here nothing of the
  # body is read until the secret matched, and nothing of it is logged.
  #
  # - The X-Telegram-Bot-Api-Secret-Token header is compared in constant time
  #   with the configured secret (threat model SR-06); a refusal is a bare
  #   401, counted, and named in the log above ten a minute, never with what
  #   was sent.
  # - An authenticated update is stored keyed by its update_id (SR-07),
  #   encrypted (SR-41), with its sender's hashed identity when it is one the
  #   bot uses (SR-42), its reading enqueued, and answered 200 whatever it
  #   holds, so Telegram never sends again one the application cannot use
  #   (SR-09); TelegramUpdateJob decides what it is.
  # - An authenticated body that is not an update at all is answered 200 too,
  #   with a line in the log, and nothing is stored.
  class Webhook
    HEADER = "HTTP_X_TELEGRAM_BOT_API_SECRET_TOKEN".freeze
    EMPTY = { "content-type" => "text/plain; charset=utf-8", "cache-control" => "no-store" }.freeze

    def call(env)
      return refuse unless authentic?(env)

      body = env["rack.input"]&.read.to_s.dup.force_encoding(Encoding::UTF_8).scrub
      update = parse(body) or return not_an_update
      event = WebhookEvent.record!(update_id: update["update_id"], kind: kind_of(update), payload: body,
                                   identity_hash: Inbound.new(update).identity)
      # An update sent again while still unread is enqueued again: its first
      # enqueue may have failed after the row was stored (the job reads it once).
      TelegramUpdateJob.perform_later(event.id) if event.received?
      answer(200)
    end

    private

    def authentic?(env)
      sent = env[HEADER].to_s
      sent.present? && ActiveSupport::SecurityUtils.secure_compare(Rails.configuration.x.telegram_webhook_secret, sent)
    end

    def refuse
      Rails.logger.warn("telegram webhook: refused, the secret did not match")
      if EdgeLimits.over?("telegram/refused", "webhook")
        Rails.logger.error("telegram webhook: more than 10 refused in a minute (threat model SR-06)")
      end
      answer(401)
    end

    # The update, or nil when the body is not one: a JSON object with an
    # integer update_id.
    def parse(body)
      update = JSON.parse(body)
      update if update.is_a?(Hash) && update["update_id"].is_a?(Integer)
    rescue JSON::ParserError, JSON::NestingError
      nil
    end

    def not_an_update
      Rails.logger.warn("telegram webhook: an authenticated body that is not an update, answered 200")
      answer(200)
    end

    # The kind of update, Telegram's name for the one field beside update_id.
    def kind_of(update)
      kind = (update.keys - [ "update_id" ]).first.to_s
      kind.match?(WebhookEvent::KIND) ? kind : "unknown"
    end

    def answer(status) = [ status, EMPTY.dup, [] ]
  end
end
