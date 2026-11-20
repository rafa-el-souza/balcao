# Cloudflare Turnstile's siteverify as the suite meets it (threat model SR-39,
# SR-29: no real HTTP). The suite holds Cloudflare's published test secret
# that always passes (config/environments/test.rb). The stub answers as
# siteverify answered when probed on 2026-11-20: that secret says yes, with
# the hostname example.com and no action, to the test site key's dummy token
# and to any other token too, though Cloudflare's docs ("Test your Turnstile
# implementation") say it refuses a real one; a token missing is
# missing-input-response; and any other secret is answered 400 with
# invalid-input-secret. A spec that needs Cloudflare's no says so with
# stub_siteverify_answer(REFUSED).
module TurnstileStubs
  SITEVERIFY = "https://challenges.cloudflare.com/turnstile/v0/siteverify".freeze
  TEST_SECRET = "1x0000000000000000000000000000000AA".freeze
  DUMMY_TOKEN = "XXXX.DUMMY.TOKEN.XXXX".freeze
  PASSED = { "success" => true, "challenge_ts" => "2026-11-20T01:00:00.000Z", "hostname" => "example.com", "error-codes" => [],
             "metadata" => { "result_with_testing_key" => true } }.freeze
  REFUSED = { "success" => false, "error-codes" => [ "invalid-input-response" ], "messages" => [] }.freeze
  MISSING = { "success" => false, "error-codes" => [ "missing-input-response" ], "messages" => [] }.freeze
  WRONG_SECRET = { "success" => false, "error-codes" => [ "invalid-input-secret" ], "messages" => [] }.freeze

  def stub_siteverify
    stub_request(:post, SITEVERIFY).to_return do |request|
      body = JSON.parse(request.body)
      status = body["secret"] == TEST_SECRET ? 200 : 400
      { status:, body: answer_to(body).to_json, headers: { "Content-Type" => "application/json" } }
    end
  end

  def answer_to(body)
    return WRONG_SECRET unless body["secret"] == TEST_SECRET
    return MISSING if body["response"].to_s.empty?

    PASSED
  end

  # Cloudflare's own answer, whatever was asked.
  def stub_siteverify_answer(answer, status: 200)
    stub_request(:post, SITEVERIFY).to_return(status:, body: answer.to_json, headers: { "Content-Type" => "application/json" })
  end
end

RSpec.configure { |config| config.include TurnstileStubs }
