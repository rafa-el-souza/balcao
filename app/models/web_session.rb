# The web visitor's identity (FR-18, threat model SR-03): a random token in an
# HttpOnly, SameSite=Strict cookie, Secure over HTTPS (production always is),
# signed with the app's secret so a forged token is never read. The API and
# the cable read the same cookie; no token travels in a header or a body.
# The database holds the token's SHA-256 only (Visitor#identity_hash): a
# 140-bit random token needs no pepper, unlike a WhatsApp id (SR-10). A
# token outlives its visitor's deletion (FR-05), so the per-visitor counter,
# keyed by the same hash, survives it too.
module WebSession
  COOKIE = :balcao_visitor
  # The retention of an unseen visitor (FR-15); each page load renews it.
  LIFETIME = 7.days
  TOKEN = /\A[1-9A-HJ-NP-Za-km-z]{24}\z/

  module_function

  # The token of a signed cookie in this jar, or nil.
  def token(cookie_jar)
    token = cookie_jar.signed[COOKIE]
    token if token.is_a?(String) && token.match?(TOKEN)
  end

  def identity_hash(token) = Digest::SHA256.hexdigest(token)

  # The hash of the cookie's token, or nil when the request carries none.
  def identity_hash_of(cookie_jar)
    token = token(cookie_jar)
    token && identity_hash(token)
  end

  # Sets the cookie with this token, a new one by default, and returns the token.
  def issue(cookie_jar, secure:, token: SecureRandom.base58(24))
    cookie_jar.signed[COOKIE] = { value: token, httponly: true, same_site: :strict, secure:,
                                  path: "/", expires: LIFETIME.from_now }
    token
  end
end
