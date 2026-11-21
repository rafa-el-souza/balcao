module Telegram
  # The delivery watch (design §9.2's M3 list, FR-19; the owner, 2026-11-15
  # and 2026-11-21): every ten minutes, beside FR-17's canary
  # (TelegramWatchJob, config/recurring.yml), it reads getWebhookInfo and
  # tells the monitor's heartbeat of its own (Heartbeat.telegram) that all is
  # well, or fails it with what it found:
  #
  # - a delivery error newer than its last look: Telegram's time and words
  #   for it (a 401 from the webhook is a secret changed on the server
  #   without the bot's task run, which no field can show, since
  #   getWebhookInfo has no secret field);
  # - a backlog of BACKLOG updates or more waiting, which a healthy webhook
  #   never leaves, since it answers within two seconds whatever it holds;
  # - a webhook Telegram holds otherwise than the bot's task sets it
  #   (Setup.differences: the URL, the kinds of update, the connection limit,
  #   no custom certificate), an empty URL among them, the webhook gone;
  # - getWebhookInfo refused or unreachable, by Telegram's code or the
  #   failure's class (Client::Error, whose message names no URL, SR-30).
  #
  # Its last look's time is kept in the cache; with none (a first run, a
  # cache that lost it or broke), an error counts when it is newer than the
  # watch's own interval, which the earlier looks would have seen. Telegram's
  # words name a delivery failure, never what an update held. On a rehearsal
  # host, with no monitor URL, it looks at nothing (design §8: a bot of its
  # own with no webhook).
  class Watch
    # Telegram sends one update at a time (Bot::MAX_CONNECTIONS) and the
    # webhook answers within two seconds, so a few waiting is a burst at work;
    # ten is no healthy minute of the demo, and the delivery errors say most
    # failures before that.
    BACKLOG = 10
    INTERVAL = 10.minutes
    LOOKED = "telegram-watch:looked-at".freeze
    # Telegram's words for an error, cut to a line's worth.
    MAX_WORDS = 200

    def initialize(client: Client.new, heartbeat: Heartbeat.telegram, cache: Rails.cache)
      @client = client
      @heartbeat = heartbeat
      @cache = cache
    end

    # What it found, empty when all is well; nil when it looked at nothing.
    def call
      return unless @heartbeat.configured?

      now = Time.current
      problems = begin
        problems_of(@client.webhook_info, since(now))
      rescue Client::Error => e
        [ "getWebhookInfo failed: #{e.message}" ]
      end
      remember(now)
      tell(problems)
      problems
    end

    private

    def problems_of(info, since)
      info = {} unless info.is_a?(Hash)
      problems = []
      differs = Setup.differences(info)
      problems << "the webhook's #{differs.to_sentence(locale: :en)} differ from what the bot's task sets" if differs.any?
      error_at = Integer(info["last_error_date"], exception: false)&.then { |seconds| Time.zone.at(seconds) }
      problems << "a delivery error at #{error_at.utc.iso8601}: #{info["last_error_message"].to_s.first(MAX_WORDS)}" if error_at && error_at > since
      waiting = info["pending_update_count"].to_i
      problems << "#{waiting} updates waiting" if waiting >= BACKLOG
      @waiting = waiting
      problems
    end

    def since(now)
      @cache.read(LOOKED) || now - INTERVAL
    rescue StandardError => e
      Rails.logger.error("telegram watch: the last look not read, #{e.class}")
      now - INTERVAL
    end

    def remember(now)
      @cache.write(LOOKED, now)
    rescue StandardError => e
      Rails.logger.error("telegram watch: this look not kept, #{e.class}")
    end

    def tell(problems)
      if problems.empty?
        Rails.logger.info("telegram watch: the webhook delivers, #{@waiting} updates waiting")
        @heartbeat.beat
      else
        Rails.logger.error("telegram watch: #{problems.join("; ")}")
        @heartbeat.failure("telegram: #{problems.join("; ")}")
      end
    end
  end
end
