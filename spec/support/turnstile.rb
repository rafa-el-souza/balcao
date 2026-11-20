# Cloudflare Turnstile's siteverify as the suite meets it (threat model SR-39,
# SR-29: no real HTTP). The suite holds Cloudflare's published test secret
# (config/environments/test.rb), which accepts only the dummy token of the test
# site keys and rejects any other (Cloudflare's docs, "Test your Turnstile
# implementation", read on 2026-11-20). The stub answers as Cloudflare answers
# that secret: success, with the hostname example.com and no action, for the
# dummy token, and invalid-input-response for anything else.
module TurnstileStubs
  SITEVERIFY = "https://challenges.cloudflare.com/turnstile/v0/siteverify".freeze
  TEST_SECRET = "1x0000000000000000000000000000000AA".freeze
  DUMMY_TOKEN = "XXXX.DUMMY.TOKEN.XXXX".freeze
  PASSED = { "success" => true, "challenge_ts" => "2026-11-20T01:00:00.000Z", "hostname" => "example.com", "error-codes" => [] }.freeze
  REFUSED = { "success" => false, "error-codes" => [ "invalid-input-response" ] }.freeze

  def stub_siteverify
    stub_request(:post, SITEVERIFY).to_return do |request|
      body = JSON.parse(request.body)
      passed = body["secret"] == TEST_SECRET && body["response"] == DUMMY_TOKEN
      { status: 200, body: (passed ? PASSED : REFUSED).to_json, headers: { "Content-Type" => "application/json" } }
    end
  end

  # Cloudflare's own answer, whatever was asked.
  def stub_siteverify_answer(answer, status: 200)
    stub_request(:post, SITEVERIFY).to_return(status:, body: answer.to_json, headers: { "Content-Type" => "application/json" })
  end
end

RSpec.configure { |config| config.include TurnstileStubs }
