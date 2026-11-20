require "net/http"

# Cloudflare Turnstile's check before a web visitor identity is minted (design
# FR-18, threat model SR-39, ADR-0012). The chat page runs the widget and
# sends its token with POST /api/session; a request that mints an identity
# asks Cloudflare's siteverify whether the token is one the widget issued,
# for this site and this action, and not yet spent. Anything else refuses the
# session: no token, Cloudflare's no, a yes for another hostname or action,
# and a siteverify that does not answer yes within FR-18's ten seconds. What
# this does follows Cloudflare's docs as read on 2026-11-20 ("Validate the
# token"): JSON to siteverify, a token of at most 2,048 characters, valid for
# five minutes and good once, which this keeps itself (first_yes?).
#
# Development, the suite and the rehearsal hosts (from M3) hold one of
# Cloudflare's published test secrets, which accept only the test site keys'
# dummy token and answer for the hostname example.com with no action, so the
# hostname and the action are checked against a real secret's answers alone;
# the boot refuses a test secret on the public name
# (config/required_environment.rb).
#
# The visitor's address is not sent (siteverify's remoteip is optional): the
# demo's host has no IPv6, so a visitor on both families may solve the
# challenge from one address and reach the server from another.
#
# Neither the token nor the secret reaches a line (SR-30): a refusal names
# Cloudflare's codes, a wrong secret as an error, since every new visitor is
# refused until the env file is fixed; a failure of the way there names its
# class.
class Turnstile
  URL = URI("https://challenges.cloudflare.com/turnstile/v0/siteverify").freeze
  ACTION = "session".freeze
  MAX_TOKEN = 2048
  # A token as Cloudflare writes one: printable ASCII, no space and no
  # control character, at most 2,048 of them. A variant of one solved token
  # (a line break after it) would hash apart from it in first_yes?, while
  # Cloudflare's decoder may read it as the same token (the fix review of
  # pull request #53, R2), so it is refused before Cloudflare is asked.
  TOKEN = /\A[\x21-\x7E]{1,#{MAX_TOKEN}}\z/
  TEST_SECRETS = %w[
    1x0000000000000000000000000000000AA 2x0000000000000000000000000000000AA 3x0000000000000000000000000000000AA
  ].freeze
  # FR-18's ten seconds, by Net::HTTP's phases: the connection, which waits
  # this long for the name and the TCP connection and again for the TLS
  # handshake, then the request's write and the answer's read.
  OPEN_TIMEOUT = 2
  WRITE_TIMEOUT = 2
  READ_TIMEOUT = 4
  # A timeout (Net::OpenTimeout, ReadTimeout, WriteTimeout), a name that does
  # not resolve, a connection refused, reset or cut (Errno's every kind), an
  # answer cut short or not HTTP, and OpenSSL's errors, a refused certificate
  # among them.
  NETWORK = [
    Timeout::Error, SocketError, SystemCallError, IOError, Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError,
    OpenSSL::SSL::SSLError
  ].freeze
  # The codes Cloudflare answers with are words and hyphens; anything else in
  # the list is not written.
  CODE = /\A[a-z][a-z-]{0,63}\z/
  # A refusal that only the env file fixes: every new visitor meets it.
  WRONG_SECRET = %w[missing-input-secret invalid-input-secret].freeze

  def self.passed?(token) = new.passed?(token)

  def initialize(secret: Rails.configuration.x.turnstile_secret_key, host: URI(Rails.configuration.x.public_origin).host)
    @secret = secret
    @host = host
  end

  # Whether Cloudflare vouches for this token, here and now.
  def passed?(token)
    return refused(:info, "no token") unless token.is_a?(String) && token.match?(TOKEN)

    answer = siteverify(token) or return false
    return refused_by(answer) unless answer["success"] == true
    return true if TEST_SECRETS.include?(@secret)
    return refused(:warn, "another hostname") unless answer["hostname"] == @host
    return refused(:warn, "another action") unless answer["action"] == ACTION

    first_yes?(token) || refused(:warn, "a token taken before")
  end

  private

  # Cloudflare's answer as a Hash, or nil (and a line) when there is none. A
  # refused token is answered 200 and a wrong secret 400, each with its code
  # (probed on 2026-11-20; the review of pull request #53): a 4xx that names
  # its codes is a refusal, never a yes, whatever else it says.
  def siteverify(token)
    http = Net::HTTP.new(URL.host, URL.port)
    http.use_ssl = true
    http.open_timeout = OPEN_TIMEOUT
    http.write_timeout = WRITE_TIMEOUT
    http.read_timeout = READ_TIMEOUT
    http.max_retries = 0
    response = http.post(URL.path, { secret: @secret, response: token }.to_json, "Content-Type" => "application/json")
    answer = object(response.body)
    if response.is_a?(Net::HTTPSuccess)
      answer || failed("siteverify answered no JSON object")
    elsif response.is_a?(Net::HTTPClientError) && answer&.key?("error-codes")
      answer.merge("success" => false)
    else
      failed("siteverify answered #{response.code}")
    end
  rescue *NETWORK => e
    failed("siteverify failed: #{e.class}")
  end

  def object(body)
    answer = JSON.parse(body.to_s)
    answer if answer.is_a?(Hash)
  rescue JSON::ParserError
    nil
  end

  # Cloudflare's check of a spent token converges in seconds, so two requests
  # close together may each hear its yes ("Validate the token", token reuse
  # and network convergence): the first yes is the only one here, the table's
  # key refusing the same token's second (review finding C2 of pull request
  # #53). The test keys skip it, as every page on them sends the one dummy
  # token.
  def first_yes?(token)
    TurnstileRedemption.create!(digest: Digest::SHA256.hexdigest(token))
    true
  rescue ActiveRecord::RecordNotUnique
    false
  end

  def refused_by(answer)
    codes = Array(answer["error-codes"]).grep(CODE)
    refused(codes.intersect?(WRONG_SECRET) ? :error : :info, codes.empty? ? "no code" : codes.join(", "))
  end

  def refused(level, why)
    Rails.logger.public_send(level, "turnstile: refused: #{why}")
    false
  end

  def failed(why)
    Rails.logger.warn("turnstile: #{why}")
    nil
  end
end
