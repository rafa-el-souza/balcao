# FR-14's per-visitor caps and per-IP limits, threat model SR-01 and SR-36,
# counted at the edge by Rack::Attack (config/initializers/rack_attack.rb)
# before a request reaches the app, and by the cable for each subscription.
# FR-14 is the home of the numbers; this is their one place in the code.
#
# A window starts at the first counted event and lasts its period (design
# §1.4): a counter is a cache entry that expires a period after its first
# increment, as Rails' own rate_limit counts. Rack::Attack's throttles count
# in windows aligned to the clock, which would let a source spend a limit
# twice across a window's edge, so the rules here are blocklists whose block
# counts. The counters live in the cache store, outside the visitor's rows,
# so a deletion does not reset them (FR-05).
module EdgeLimits
  Limit = Data.define(:name, :limit, :period, :reply)

  LIMITS = [
    # Every API and cable request of one source from the web app (its origin
    # or its cookie), and every cable subscription.
    Limit.new(name: "ip/requests", limit: 60, period: 1.minute, reply: :now),
    # The same for the requests of one source that are neither, counted apart,
    # so a hostile page whose visitors' browsers post here cannot use up the
    # minute of the web app's own pages behind the same address (review
    # finding C2 of pull request #12). The app refuses them all but a trace
    # page's lookup, which a link opened without the cookie makes (FR-12,
    # threat model SR-11).
    Limit.new(name: "ip/anonymous", limit: 60, period: 1.minute, reply: :now),
    # Every request of one source from the public origin that would mint a
    # session, one with no cookie whose signature verifies, whether
    # Turnstile's check then lets it or not: the edge cannot know the check's
    # answer, and the count is also what bounds the calls to Cloudflare (SR-39;
    # the owner, 2026-11-20, on the review of pull request #53). A page load
    # that brings back its cookie mints nothing, nor does a request the app
    # refuses for its origin.
    Limit.new(name: "ip/sessions", limit: 20, period: 1.hour, reply: :now),
    # Every turn of one source from the public origin, whoever's.
    Limit.new(name: "ip/turns", limit: 200, period: 1.day, reply: :today),
    # Every turn of one visitor identity.
    Limit.new(name: "visitor/minute", limit: 10, period: 1.minute, reply: :now),
    Limit.new(name: "visitor/day", limit: 40, period: 1.day, reply: :today),
    # The Telegram webhook's refusals, all sources together: the first of a
    # minute and the eleventh, the alert, are named in the log (threat model
    # SR-06); nothing is refused for them.
    Limit.new(name: "telegram/refused", limit: 10, period: 1.minute, reply: nil),
    # A limit's own line goes to a Telegram visitor at most once a minute, so
    # a flood costs no stream of replies (FR-19).
    Limit.new(name: "telegram/limit_line", limit: 1, period: 1.minute, reply: nil)
  ].index_by(&:name).freeze

  module_function

  # Counts one event of this discriminator and answers whether it went past
  # the limit. A nil discriminator is not counted.
  def over?(name, discriminator)
    return false if discriminator.nil?

    limit = LIMITS.fetch(name)
    count(limit, discriminator) > limit.limit
  end

  # The stores in use (Solid Cache, and the memory store of the specs) start
  # a missing counter at 1 themselves, so an increment that answers nil
  # failed. A cache that cannot count (its database down or slow, Solid
  # Cache's failsafe answering nil) lets the event through uncounted, and the
  # log names the limit, never the source: the month's budget cap still
  # bounds the spend (FR-14; review finding C4 of pull request #12, the
  # owner's decision of 2026-11-14). Before, every API request answered 500;
  # and a write after a failed increment started a live counter over
  # (review finding S4 of pull request #29). The decision holds for every
  # error of the cache, not only those its failsafe answers nil for: one it
  # raises is let through the same way, named by its class alone, never by
  # its message, which may quote the key (SR-30; review finding M4 of pull
  # request #32, the owner's word of 2026-11-15).
  def count(limit, discriminator)
    store = Rack::Attack.cache.store
    key = "limits:#{limit.name}:#{discriminator}"
    one_at_a_time(store, key) { store.increment(key, 1, expires_in: limit.period) } || uncounted(limit)
  rescue StandardError => e
    uncounted(limit, "the cache raised #{e.class}")
  end

  # The key travels as a parameter, never in the statement's text, as
  # AdvisoryLock's does: it names an address or an identity's hash (threat
  # model SR-30). The lock's own result is void, so the statement answers 1.
  XACT_LOCK = "SELECT 1 FROM (SELECT pg_advisory_xact_lock(hashtextextended($1, 0))) AS locked".freeze

  # Solid Cache counts a key under its row's lock, and a key with no row yet
  # has none to lock: two first counts of a window each read no row and each
  # wrote 1, so a source's requests at once each counted as its window's
  # first (review finding V1 of pull request #53, M2's first close). A lock
  # on the key for the count's transaction, taken on the cache's own
  # connection before the count, makes the second wait for the first's row.
  # The memory store of the specs counts under its own lock.
  def one_at_a_time(store, key)
    return yield unless store.is_a?(SolidCache::Store)

    store.connections.with_connection_for(key) do
      SolidCache::Record.transaction do
        SolidCache::Record.connection.select_value(XACT_LOCK, "EdgeLimits", [ key ])
        yield
      end
    end
  end

  def uncounted(limit, why = "the cache did not answer")
    Rails.logger.warn("limits: #{limit.name} not counted: #{why}")
    0
  end

  # Deletes the counters first written before the time given, for the
  # nightly job (FR-15, the privacy page; design §10, note of 2026-11-14,
  # PR-17): they key by an IP address or an identity's hash, and Solid Cache
  # alone deletes a row two weeks after it was first written, and only when
  # later writes set its expiry off. Solid Cache never moves a row's creation
  # time, so a counter still counting is deleted too, which may restart a
  # live window at most once a week. Any other store (the memory store of the
  # specs) keeps its counters in memory, and nothing is deleted there. The
  # rows go in batches, each its own statement, under the statement timeout
  # (SR-20; review finding S5 of pull request #29).
  def purge(before, batch: 1_000)
    store = Rack::Attack.cache.store
    return 0 unless store.is_a?(SolidCache::Store)

    prefix = [ store.options[:namespace], "limits:" ].compact.join(":")
    SolidCache::Entry.where("key LIKE ?", "#{ActiveRecord::Base.sanitize_sql_like(prefix)}%")
                     .where(created_at: ...before).in_batches(of: batch).delete_all
  end

  # --- Which requests count (Rack::Attack's request, a Rack::Request) --------
  #
  # Rack::Attack normalizes PATH_INFO with the router's own normalize_path
  # before these run (rack-attack 6.8.0), so a path with a repeated or a
  # trailing slash is read as the router reads it, and counted
  # (spec/requests/rate_limits_spec.rb; review findings C1 and V4 of pull
  # request #17).

  def api?(request) = request.path.start_with?("/api/") || request.path == "/cable"

  # A browser sets Origin itself, so another site's page cannot send ours; a
  # script can, and is then counted like the web app.
  def public_origin?(request) = request.get_header("HTTP_ORIGIN") == Rails.configuration.x.public_origin

  # The web app's request: from its origin, or with its cookie, which
  # SameSite=Strict keeps off another site's requests.
  def from_app?(request) = public_origin?(request) || !visitor(request).nil?

  def new_session?(request)
    request.post? && request.path == "/api/session" && public_origin?(request) && visitor(request).nil?
  end

  def turn?(request) = request.post? && request.path == "/api/messages" && public_origin?(request)

  # The hash of the visitor cookie's token, read once per request.
  def visitor(request)
    request.env.fetch("balcao.visitor") do
      request.env["balcao.visitor"] = WebSession.identity_hash_of(ActionDispatch::Request.new(request.env).cookie_jar)
    end
  end

  def source_of(request) = request.env.fetch("balcao.source") { request.env["balcao.source"] = source(request.env) }

  # The client's address as the trusted proxy reports it (SR-36: kamal-proxy
  # sets X-Forwarded-For, and only a private address is a trusted proxy),
  # IPv6 aggregated by /64 and an IPv4-mapped address read as IPv4.
  def source(env)
    address = IPAddr.new(ActionDispatch::Request.new(env).remote_ip.to_s)
    address = address.native
    address.ipv6? ? "#{address.mask(64)}/64" : address.to_s
  rescue IPAddr::Error
    nil
  end

  # The fixed reply of a refused request: 429, no model call, nothing stored.
  def response(env)
    limit = LIMITS.fetch(env["rack.attack.matched"])
    text = I18n.t("limits.#{limit.reply}", locale: RequestLanguage.of(env["HTTP_ACCEPT_LANGUAGE"]))
    [ 429, { "content-type" => "application/json; charset=utf-8", "cache-control" => "no-store" },
      [ { error: "limit", text: }.to_json ] ]
  end
end
