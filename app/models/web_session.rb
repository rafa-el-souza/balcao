# The web visitor's identity (FR-18, threat model SR-03): a random token in an
# HttpOnly, SameSite=Strict cookie, Secure over HTTPS (production always is),
# signed with the app's secret so a forged token is never read. The API and
# the cable read the same cookie; no token travels in a header or a body.
# The database holds the token's SHA-256 only (Visitor#identity_hash): a
# 140-bit random token needs no pepper, unlike a WhatsApp id (SR-10). A
# token outlives its visitor's deletion (FR-05), so the per-visitor counter,
# keyed by the same hash, survives it too.
module WebSession
  # The cookie's name over HTTPS, as production always is (threat model R7,
  # closed at M3-6; the security scan's F1 of 2026-11-21): a browser keeps a
  # __Host- cookie only when this host itself sets it, Secure, with Path=/
  # and no Domain, so no other name under rafasouza.dev.br, a sibling or a
  # network attacker answering as one over plain HTTP, can plant one for the
  # visitor to adopt. Plain HTTP (development, the suite's requests) keeps the
  # bare name, since a browser refuses the prefix on a cookie that is not
  # Secure. The bare name is never read over HTTPS, which would let a planted
  # cookie back in: a clean cut with no migration, the MVP host's visitors
  # starting over at the production cut (design §9.2).
  NAME = "__Host-balcao_visitor".freeze
  PLAIN_NAME = "balcao_visitor".freeze
  # The retention of an unseen visitor (FR-15); each page load renews it.
  LIFETIME = 7.days
  TOKEN = /\A[1-9A-HJ-NP-Za-km-z]{24}\z/

  module_function

  # The cookie's name for this request: the __Host- one over HTTPS.
  def name(request) = request.ssl? ? NAME : PLAIN_NAME

  # The token of the request's signed cookie, or nil.
  def token(request)
    token = request.cookie_jar.signed[name(request)]
    token if token.is_a?(String) && token.match?(TOKEN)
  end

  def identity_hash(token) = Digest::SHA256.hexdigest(token)

  # The hash of the cookie's token, or nil when the request carries none.
  def identity_hash_of(request)
    token = token(request)
    token && identity_hash(token)
  end

  # Sets the request's cookie with this token, a new one by default, and
  # returns the token: Secure exactly when its name carries the prefix, since Rails writes
  # no Secure cookie on a plain request and a browser keeps no __Host- one
  # that is not Secure.
  def issue(request, token: SecureRandom.base58(24))
    request.cookie_jar.signed[name(request)] = { value: token, httponly: true, same_site: :strict, secure: request.ssl?,
                                                 path: "/", expires: LIFETIME.from_now }
    token
  end
end
