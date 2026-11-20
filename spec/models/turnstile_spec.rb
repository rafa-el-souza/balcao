require "rails_helper"

# Cloudflare Turnstile's check before a web visitor identity is minted (design
# FR-18, threat model SR-39, ADR-0012): the token the page's widget gave is
# asked of Cloudflare's siteverify, within FR-18's ten seconds, and anything
# but Cloudflare's yes, for this site and this action, refuses.
RSpec.describe "SR-39 FR-18 Turnstile's check of a token" do
  let(:real_secret) { "0x4AAAAAAAreal-secret-for-the-specs" }
  let(:host) { "balcao.example" }
  let(:check) { Turnstile.new(secret: real_secret, host:) }

  def passed(**fields)
    { "success" => true, "challenge_ts" => "2026-11-20T01:00:00.000Z", "hostname" => host, "error-codes" => [],
      "action" => "session" }.merge(fields.transform_keys(&:to_s))
  end

  describe "the test keys' path, as development, CI and the rehearsal hosts run it" do
    let(:check) { Turnstile.new(secret: TurnstileStubs::TEST_SECRET, host:) }

    it "passes the test site key's dummy token, which Cloudflare's test secret answers for example.com with no action" do
      stub_siteverify

      expect(check.passed?(TurnstileStubs::DUMMY_TOKEN)).to be true
    end

    # Probed on 2026-11-20: the test secret said yes to any token, though
    # Cloudflare's docs say it refuses a real one; so the boot refuses it on
    # the public name (config/required_environment.rb).
    it "passes any token the test secret is given, as Cloudflare answered it when probed" do
      stub_siteverify

      expect(check.passed?("0.real-looking-token")).to be true
    end

    it "is the suite's own configuration: the published test secret that always passes" do
      expect(Rails.configuration.x.turnstile_secret_key).to eq TurnstileStubs::TEST_SECRET
    end
  end

  it "asks siteverify with the secret and the token as JSON, and sends no visitor address" do
    stub = stub_request(:post, TurnstileStubs::SITEVERIFY)
           .with(body: { secret: real_secret, response: "0.token" }.to_json, headers: { "Content-Type" => "application/json" })
           .to_return(status: 200, body: passed.to_json)

    expect(check.passed?("0.token")).to be true
    expect(stub).to have_been_requested.once
  end

  describe "with a real secret, Cloudflare's yes counts only for this site and this action" do
    it "refuses a token solved on another hostname" do
      stub_siteverify_answer(passed(hostname: "elsewhere.example"))

      expect(check.passed?("0.token")).to be false
    end

    it "refuses a token solved for another action, or for none" do
      stub_siteverify_answer(passed(action: "login"))
      expect(check.passed?("0.token")).to be false

      stub_siteverify_answer(passed.except("action"))
      expect(check.passed?("0.token")).to be false
    end

    it "refuses an answer whose success is anything but true" do
      [ "true", 1, nil ].each do |success|
        stub_siteverify_answer(passed(success:))
        expect(check.passed?("0.token")).to be false
      end
    end
  end

  # Review finding C2 of pull request #53: Cloudflare's check of a spent
  # token converges in seconds, and repeats close together may each hear
  # yes ("Validate the token", token reuse and network convergence): the
  # first yes is the only one here.
  describe "SR-39 a token mints once" do
    it "takes a token once: a second yes for it refuses, with a line, keeping only the token's digest" do
      allow(Rails.logger).to receive(:warn)
      stub_siteverify_answer(passed)

      expect(check.passed?("0.one-solved-token")).to be true
      expect(check.passed?("0.one-solved-token")).to be false
      expect(TurnstileRedemption.sole.digest).to eq Digest::SHA256.hexdigest("0.one-solved-token")
      expect(Rails.logger).to have_received(:warn).with("turnstile: refused: a token taken before")
    end

    # The fix review of pull request #53 (R2): a variant of one solved token
    # (a line break after it) hashes apart, and Cloudflare's decoder may read
    # it as the same token. Cloudflare's tokens hold no space and no control
    # character.
    it "refuses a token with a space or a control character, asking Cloudflare nothing, so a variant is never a second token" do
      stub_siteverify_answer(passed)

      expect(check.passed?("0.one-solved-token")).to be true
      [ "0.one-solved-token\n", " 0.one-solved-token", "0.one-solved-token\r\n", "0.one\tsolved-token",
        "0.one-solved-tokén" ].each do |variant|
        expect(check.passed?(variant)).to be false
      end
      expect(a_request(:post, TurnstileStubs::SITEVERIFY)).to have_been_made.once
    end

    it "keeps nothing of a token Cloudflare refused, nor of another site's or action's yes" do
      stub_siteverify_answer({ "success" => false, "error-codes" => [ "invalid-input-response" ] })
      check.passed?("0.refused")
      stub_siteverify_answer(passed(hostname: "elsewhere.example"))
      check.passed?("0.elsewhere")

      expect(TurnstileRedemption.count).to eq 0
    end

    it "passes the test keys' dummy token as often as it comes and keeps nothing, since every page on a test key sends it" do
      check = Turnstile.new(secret: TurnstileStubs::TEST_SECRET, host:)
      stub_siteverify

      expect(3.times.map { check.passed?(TurnstileStubs::DUMMY_TOKEN) }).to all(be true)
      expect(TurnstileRedemption.count).to eq 0
    end
  end

  describe "a token that is not one asks Cloudflare nothing" do
    [ nil, "", 7, [ "0.token" ], { "token" => "0.token" }, "x" * 2049 ].each do |token|
      it "refuses #{token.inspect.truncate(24)}" do
        expect(check.passed?(token)).to be false
        expect(a_request(:post, TurnstileStubs::SITEVERIFY)).not_to have_been_made
      end
    end

    it "takes a token of 2,048 characters, Cloudflare's longest" do
      stub_siteverify_answer(passed)

      expect(check.passed?("x" * 2048)).to be true
    end
  end

  describe "a siteverify that does not answer yes refuses" do
    it "on Cloudflare's refusal, each of its codes" do
      %w[missing-input-secret invalid-input-secret missing-input-response invalid-input-response bad-request
         timeout-or-duplicate internal-error].each do |code|
        stub_siteverify_answer({ "success" => false, "error-codes" => [ code ] })
        expect(check.passed?("0.token")).to be false
      end
    end

    it "on a timeout, a broken connection, a refused certificate, an error status or an answer that is not JSON" do
      [ -> { stub_request(:post, TurnstileStubs::SITEVERIFY).to_timeout },
        -> { stub_request(:post, TurnstileStubs::SITEVERIFY).to_raise(SocketError) },
        -> { stub_request(:post, TurnstileStubs::SITEVERIFY).to_raise(Errno::ECONNRESET) },
        -> { stub_request(:post, TurnstileStubs::SITEVERIFY).to_raise(OpenSSL::SSL::SSLError) },
        -> { stub_request(:post, TurnstileStubs::SITEVERIFY).to_raise(EOFError) },
        -> { stub_siteverify_answer(passed, status: 500) },
        -> { stub_request(:post, TurnstileStubs::SITEVERIFY).to_return(status: 200, body: "<html>oops</html>") },
        -> { stub_request(:post, TurnstileStubs::SITEVERIFY).to_return(status: 200, body: "[true]") } ].each do |stub|
        WebMock.reset!
        stub.call
        expect(check.passed?("0.token")).to be false
      end
    end
  end

  it "waits at most FR-18's ten seconds: the connection and its handshake, the request and the answer" do
    expect(Turnstile::OPEN_TIMEOUT * 2 + Turnstile::WRITE_TIMEOUT + Turnstile::READ_TIMEOUT).to be <= 10
    http = Net::HTTP.new("challenges.cloudflare.com", 443)
    allow(Net::HTTP).to receive(:new).and_return(http)
    stub_siteverify_answer(passed)

    check.passed?("0.token")

    expect([ http.use_ssl?, http.open_timeout, http.write_timeout, http.read_timeout, http.max_retries ])
      .to eq([ true, Turnstile::OPEN_TIMEOUT, Turnstile::WRITE_TIMEOUT, Turnstile::READ_TIMEOUT, 0 ])
  end

  # Threat model SR-30: the token and the secret never reach a line; a
  # refusal names Cloudflare's codes, a failure of the way there its class.
  describe "the log" do
    let(:lines) { [] }

    before do
      %i[info warn error].each do |level|
        allow(Rails.logger).to receive(level) { |line| lines << [ level, line ] }
      end
    end

    # Probed on 2026-11-20: a wrong secret is answered 400, with its code,
    # where a refused token is answered 200 (the review of pull request #53;
    # the Rails finder's third note).
    it "names a wrong secret as an error from the 400 Cloudflare answers it with" do
      stub_siteverify_answer({ "success" => false, "error-codes" => [ "invalid-input-secret" ], "messages" => [] }, status: 400)

      expect(check.passed?("0.token-of-the-visitor")).to be false
      expect(lines).to eq([ [ :error, "turnstile: refused: invalid-input-secret" ] ])
    end

    # The fix review of pull request #53 (its note on c7524fd): a request
    # Cloudflare calls malformed is ours, and every new visitor meets it.
    it "names a request Cloudflare calls malformed as an error, as a wrong secret" do
      stub_siteverify_answer({ "success" => false, "error-codes" => [ "bad-request" ], "messages" => [] }, status: 400)

      expect(check.passed?("0.token-of-the-visitor")).to be false
      expect(lines).to eq([ [ :error, "turnstile: refused: bad-request" ] ])
    end

    it "takes no yes from an answer that is not 200, whatever its body says" do
      stub_siteverify_answer(passed, status: 400)

      expect(check.passed?("0.token-of-the-visitor")).to be false
    end

    it "names Cloudflare's codes of a refusal, and a wrong secret as an error" do
      stub_siteverify_answer({ "success" => false, "error-codes" => [ "timeout-or-duplicate" ] })
      check.passed?("0.token-of-the-visitor")
      stub_siteverify_answer({ "success" => false, "error-codes" => [ "invalid-input-secret" ] })
      check.passed?("0.token-of-the-visitor")

      expect(lines).to eq([ [ :info, "turnstile: refused: timeout-or-duplicate" ],
                            [ :error, "turnstile: refused: invalid-input-secret" ] ])
    end

    it "names a token with no answer of its own, another site's or action's yes, and a failure of the way there by its class" do
      check.passed?(nil)
      stub_siteverify_answer(passed(hostname: "elsewhere.example"))
      check.passed?("0.token-of-the-visitor")
      stub_siteverify_answer(passed(action: "login"))
      check.passed?("0.token-of-the-visitor")
      stub_request(:post, TurnstileStubs::SITEVERIFY).to_timeout
      check.passed?("0.token-of-the-visitor")
      stub_siteverify_answer(passed, status: 503)
      check.passed?("0.token-of-the-visitor")

      expect(lines).to eq([ [ :info, "turnstile: refused: no token" ],
                            [ :warn, "turnstile: refused: another hostname" ],
                            [ :warn, "turnstile: refused: another action" ],
                            [ :warn, "turnstile: siteverify failed: Net::OpenTimeout" ],
                            [ :warn, "turnstile: siteverify answered 503" ] ])
    end

    it "never writes the token or the secret, nor a code that is not a code" do
      stub_siteverify_answer({ "success" => false, "error-codes" => [ "0.token-of-the-visitor", "invalid-input-response" ] })
      check.passed?("0.token-of-the-visitor")

      expect(lines.map(&:last).join).not_to include("token-of-the-visitor", real_secret)
      expect(lines).to eq([ [ :info, "turnstile: refused: invalid-input-response" ] ])
    end

    it "writes nothing when Cloudflare says yes" do
      stub_siteverify_answer(passed)
      check.passed?("0.token-of-the-visitor")

      expect(lines).to be_empty
    end
  end
end
