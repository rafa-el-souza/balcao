module Webhooks
  # POST /webhooks/telegram (FR-19, design §6.6), the Telegram bot's inbound
  # edge:
  #
  # - the X-Telegram-Bot-Api-Secret-Token header is compared in constant time
  #   with the configured secret before the body is read (threat model SR-06);
  #   a refusal is a bare 401, counted, and named in the log above ten a
  #   minute, never with what was sent;
  # - an authenticated update is stored keyed by its update_id (SR-07),
  #   encrypted (SR-41), its reading enqueued, and answered 200 whatever it
  #   holds, so Telegram never sends again one the application cannot use
  #   (SR-09); the job decides what it is (TelegramUpdateJob, SR-42);
  # - an authenticated body that is not an update at all is answered 200 too,
  #   with a line in the log, and nothing is stored.
  #
  # Rails reads no JSON body as parameters (config/initializers/
  # parameter_parsers.rb), so nothing of the body reaches the request's log
  # line; the body is read here, after the secret, and logged as its
  # update_id alone (SR-30).
  class TelegramController < ApplicationController
    HEADER = "X-Telegram-Bot-Api-Secret-Token".freeze

    def create
      return refuse unless authentic?

      body = request.raw_post.to_s.dup.force_encoding(Encoding::UTF_8).scrub
      update = parse(body) or return not_an_update
      event = WebhookEvent.record!(update_id: update["update_id"], kind: kind_of(update), payload: body)
      # An update sent again while still unread is enqueued again: its first
      # enqueue may have failed after the row was stored (the job reads it once).
      TelegramUpdateJob.perform_later(event.id) if event.received?
      head :ok
    end

    private

    def authentic?
      sent = request.headers[HEADER].to_s
      expected = Rails.configuration.x.telegram_webhook_secret
      sent.present? && ActiveSupport::SecurityUtils.secure_compare(expected, sent)
    end

    def refuse
      Rails.logger.warn("telegram webhook: refused, the secret did not match")
      if EdgeLimits.over?("telegram/refused", "webhook")
        Rails.logger.error("telegram webhook: more than 10 refused in a minute (threat model SR-06)")
      end
      head :unauthorized
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
      head :ok
    end

    # The kind of update, Telegram's name for the one field beside update_id.
    def kind_of(update)
      kind = (update.keys - [ "update_id" ]).first.to_s
      kind.match?(WebhookEvent::KIND) ? kind : "unknown"
    end
  end
end
