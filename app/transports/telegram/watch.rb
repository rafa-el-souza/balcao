module Telegram
  # The delivery watch (design §9.2's M3 list, FR-19; the owner, 2026-11-15
  # and 2026-11-21): every ten minutes, beside FR-17's canary
  # (TelegramWatchJob, config/recurring.yml), it reads getWebhookInfo and
  # tells the monitor's heartbeat of its own (Heartbeat.telegram) that all is
  # well, or fails it with what it found:
  #
  # - a delivery error newer than the last one it told, and updates still
  #   waiting after one (below): Telegram's time and words for it (a 401
  #   from the webhook is a secret changed on the server without the bot's
  #   task run, which no field can show, since getWebhookInfo has no secret
  #   field);
  # - a backlog of BACKLOG updates or more waiting, which a healthy webhook
  #   never leaves, since it answers within two seconds whatever it holds;
  # - a webhook Telegram holds otherwise than the bot's task sets it
  #   (Setup.differences: the URL, the kinds of update, the connection limit,
  #   no custom certificate), an empty URL among them, the webhook gone;
  # - getWebhookInfo refused or unreachable, by Telegram's code or the
  #   failure's class (Client::Error's, never its description, SR-30).
  #
  # What it told is kept in the cache on Telegram's own clock: the date of
  # the last delivery error the monitor took, written once the monitor took
  # it, so an error whose /fail did not reach it is told again; and the
  # date of the last error when the updates last drained. An error is new
  # when its date is past the one told; with none kept (a first run, a
  # cache that lost it or broke), when it is newer than the watch's own
  # interval, which the earlier looks would have seen (review findings C2,
  # C4, H12 and H13 of pull request #64: the look's own time, before its
  # request and in fractions of a second, told an error twice or never).
  # Telegram tries a failed update again in its own time, so while updates
  # wait after an error, from before the last time they drained, the watch
  # keeps failing, not only at a newer error (H3). Telegram's words for an
  # error name a delivery failure, never an update's content; a refused call
  # is named by Telegram's code or the failure's class, never its
  # description (C5, as every caller of the client logs it, SR-30). On a
  # rehearsal host, with no monitor URL, it looks at nothing (design §8: a
  # bot of its own with no webhook).
  class Watch
    # Telegram sends one update at a time (Bot::MAX_CONNECTIONS) and the
    # webhook answers within two seconds, so a few waiting is a burst at work;
    # ten is no healthy minute of the demo, and the delivery errors say most
    # failures before that.
    BACKLOG = 10
    INTERVAL = 10.minutes
    # Telegram's dates, in its whole seconds: the last delivery error a look
    # the monitor took had seen (0 for none), and the last error when the
    # updates last drained.
    TOLD = "telegram-watch:told".freeze
    DRAINED = "telegram-watch:drained".freeze
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

      info = begin
        @client.webhook_info
      rescue Client::Error => e
        return [ "getWebhookInfo failed: #{e.code || e.failure || "refused, with no code"}" ].tap { |problems| tell(problems) }
      end
      info = {} unless info.is_a?(Hash)
      error = Integer(info["last_error_date"], exception: false)
      waiting = info["pending_update_count"].to_i
      problems = problems_of(info, error, waiting)
      write(TOLD, error || 0) if tell(problems)
      write(DRAINED, error || 0) if waiting.zero?
      problems
    end

    private

    def problems_of(info, error, waiting)
      problems = []
      differs = Setup.differences(info)
      problems << "the webhook's #{differs.to_sentence(locale: :en)} differ from what the bot's task sets" if differs.any?
      @waiting = waiting
      if error
        words = "a delivery error at #{Time.zone.at(error).utc.iso8601}: #{info["last_error_message"].to_s.first(MAX_WORDS)}"
        if newer?(error, TOLD) then problems << words
        elsif waiting.positive? && undrained?(error) then return problems << "#{waiting} updates waiting since #{words}"
        end
      end
      problems << "#{waiting} updates waiting" if waiting >= BACKLOG
      problems
    end

    # Past the date kept, or, with none, within the watch's interval.
    def newer?(error, key)
      kept = read(key)
      kept.nil? ? error > (Time.current - INTERVAL).to_i : error > kept
    end

    # Whether the updates have not drained since the error: with no drain
    # kept (a first run, a cache entry expired or lost), they have not, so
    # updates waiting after an error the watch told keep it failing (the
    # fix review's R2 on pull request #64).
    def undrained?(error)
      drained = read(DRAINED)
      drained.nil? || error > drained
    end

    def read(key)
      @cache.read(key)
    rescue StandardError => e
      Rails.logger.error("telegram watch: #{key} not read, #{e.class}")
      nil
    end

    def write(key, value)
      @cache.write(key, value)
    rescue StandardError => e
      Rails.logger.error("telegram watch: #{key} not kept, #{e.class}")
    end

    # Whether the monitor took it.
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
