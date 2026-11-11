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
    # Every API and cable request of one source, and every cable subscription.
    Limit.new(name: "ip/requests", limit: 60, period: 1.minute, reply: :now),
    # Every session minted for one source: a page load that brings back its
    # cookie mints nothing.
    Limit.new(name: "ip/sessions", limit: 20, period: 1.hour, reply: :now),
    # Every turn of one source, whoever's.
    Limit.new(name: "ip/turns", limit: 200, period: 1.day, reply: :today),
    # Every turn of one visitor identity.
    Limit.new(name: "visitor/minute", limit: 10, period: 1.minute, reply: :now),
    Limit.new(name: "visitor/day", limit: 40, period: 1.day, reply: :today)
  ].index_by(&:name).freeze

  module_function

  # Counts one event of this discriminator and answers whether it went past
  # the limit. A nil discriminator is not counted.
  def over?(name, discriminator)
    return false if discriminator.nil?

    limit = LIMITS.fetch(name)
    count(limit, discriminator) > limit.limit
  end

  def count(limit, discriminator)
    store = Rack::Attack.cache.store
    key = "limits:#{limit.name}:#{discriminator}"
    store.increment(key, 1, expires_in: limit.period) || (store.write(key, 1, expires_in: limit.period) && 1)
  end

  # --- Which requests count (Rack::Attack's request, a Rack::Request) --------

  def api?(request) = request.path.start_with?("/api/") || request.path == "/cable"

  def new_session?(request) = request.post? && request.path == "/api/session" && visitor(request).nil?

  def turn?(request) = request.post? && request.path == "/api/messages"

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
