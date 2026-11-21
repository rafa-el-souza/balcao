require "rails_helper"

# A new visitor identity is minted only with the token of Turnstile's widget,
# which Cloudflare's siteverify accepts (SR-39, from M2's first slice), beside
# the per-IP limit on new sessions (spec/requests/rate_limits_spec.rb). The
# suite's siteverify answers as Cloudflare answers the published test keys
# (spec/support/turnstile.rb).
RSpec.describe "FR-18 SR-03 POST /api/session issues the visitor cookie", type: :request do
  before { stub_siteverify }

  # The body of a session the page mints: the widget's token beside the rest.
  def minting(body = {}) = { turnstile_token: TurnstileStubs::DUMMY_TOKEN }.merge(body)

  it "sets an HttpOnly, SameSite=Strict cookie and answers the open conversation, its trace token and language" do
    expect { api_post "/api/session", minting }.to change(Visitor, :count).by(1).and change(Conversation, :count).by(1)

    expect(response).to have_http_status(:created)
    conversation = Conversation.sole
    expect(json).to eq("conversation_id" => conversation.id, "trace_token" => conversation.trace_token, "language" => "pt-BR",
                       "mode" => "normal", "brl" => { "per_usd" => 5.6518, "verified_on" => "2026-11-13" })
    cookie = response.headers["Set-Cookie"]
    expect(cookie).to match(/\A#{WebSession::PLAIN_NAME}=/o)
    expect(cookie).to include("httponly").and include("samesite=strict").and include("path=/")
    expect(cookie_visitor).to eq conversation.visitor
    expect(conversation.visitor).to have_attributes(channel: "web")
  end

  # The glass box's head shows the budget's mode, and its costs in reais
  # beside the dollars (FR-12, FR-14; design §10, note of 2026-11-12).
  it "answers the month's budget mode and the rate of the real with its date" do
    api_post "/api/session", minting

    expect(json).to include("mode" => "normal", "brl" => { "per_usd" => 5.6518, "verified_on" => "2026-11-13" })

    BudgetState.for_month!.update!(forced_mode: "paused")
    api_post "/api/session"

    expect(json["mode"]).to eq("paused")
  end

  # Threat model R7, closed at M3-6 (and the security scan's F1 of
  # 2026-11-21): over HTTPS, as production always is, the cookie carries the
  # __Host- prefix, which a browser keeps only when this host itself sets it,
  # Secure, with Path=/ and no Domain, so no other name under the domain, a
  # sibling or a network attacker answering as one over plain HTTP, can plant
  # one for the visitor to adopt.
  it "names the cookie __Host-balcao_visitor over HTTPS, Secure, with Path=/ and no Domain (R7)" do
    https!
    api_post "/api/session", minting

    cookie = response.headers["Set-Cookie"]
    expect(cookie).to start_with("__Host-balcao_visitor=")
    expect(cookie).to include("secure").and include("path=/").and include("httponly").and include("samesite=strict")
    expect(cookie).not_to match(/domain=/i)
  end

  it "answers the same visitor when the __Host- cookie comes back over HTTPS, creating nothing" do
    https!
    api_post "/api/session", minting
    first = Visitor.sole

    expect { api_post "/api/session" }.not_to change(Visitor, :count)
    expect(response).to have_http_status(:created)
    expect(json["conversation_id"]).to eq first.conversations.sole.id
  end

  # A clean cut, with no migration (R7): reading the bare name over HTTPS
  # would let a planted cookie back in.
  it "reads no cookie of the bare name over HTTPS: one signed and valid is not adopted, and mints nothing without a token" do
    start_session
    https!

    expect { api_post "/api/session" }.not_to change(Visitor, :count)
    expect(response).to have_http_status(:forbidden)
    expect(json).to eq("error" => "challenge")
    get "/api/conversations/current"
    expect(response).to have_http_status(:unauthorized)
  end

  it "keeps the visitor's token out of the body and of every header but Set-Cookie (no token in a header)" do
    api_post "/api/session", minting

    expect(cookie_token).to match(/\A[1-9A-HJ-NP-Za-km-z]{24}\z/)
    expect(response.body).not_to include(cookie_token)
    expect(response.headers.except("Set-Cookie").values.join).not_to include(cookie_token)
  end

  it "stores the SHA-256 of the token, never the token" do
    api_post "/api/session", minting

    expect(cookie_visitor.identity_hash).to eq Digest::SHA256.hexdigest(cookie_token)
    expect(Visitor.where(identity_hash: cookie_token)).to be_empty
  end

  it "answers the same visitor and conversation when the cookie comes back, creating nothing" do
    first = start_session

    expect { api_post "/api/session" }.not_to change(Visitor, :count)
    expect(response).to have_http_status(:created)
    expect(json["conversation_id"]).to eq first.conversations.sole.id
    expect(cookie_visitor).to eq first
  end

  it "takes the page's language for a conversation with no reply yet, one of the three" do
    start_session(language: "es")

    expect(json["language"]).to eq "es"
    expect(Conversation.sole.language).to eq "es"
  end

  it "keeps the language a conversation already replied in" do
    visitor = start_session(language: "en")
    conversation = visitor.conversations.sole
    turn = Turn.for_inbound!(Message.record_inbound!(conversation:, external_id: SecureRandom.uuid, body: "hi"))
    Message.record_outbound!(turn:, body: "Hello")

    api_post "/api/session", { language: "es" }

    expect(json["language"]).to eq "en"
  end

  [ "fr", "", 1, nil, [ "es" ], { "x" => 1 } ].each do |language|
    it "ignores a language outside the three (#{language.inspect})" do
      api_post "/api/session", minting(language:)

      expect(response).to have_http_status(:created)
      expect(json["language"]).to eq "pt-BR"
    end
  end

  it "mints a new visitor for a cookie whose signature does not verify, with the widget's token" do
    cookies[WebSession::PLAIN_NAME.to_s] = "forged-token"

    expect { api_post "/api/session" }.not_to change(Visitor, :count)
    expect(json).to eq("error" => "challenge")

    expect { api_post "/api/session", minting }.to change(Visitor, :count).by(1)
    expect(cookie_visitor).to be_present
  end

  it "starts over with the same token after the visitor deleted its data (FR-05)" do
    visitor = start_session
    identity = visitor.identity_hash
    visitor.erase!

    expect { api_post "/api/session" }.to change(Visitor, :count).by(1)
    expect(Visitor.sole.identity_hash).to eq identity
  end

  # Threat model SR-39, ADR-0012: a script that changes cookies mints no
  # identity without solving Cloudflare's challenge.
  describe "SR-39 Turnstile's token, where a session mints an identity" do
    it "refuses a session without the token with the retry hint, creating nothing, setting no cookie and asking Cloudflare nothing" do
      [ -> { api_post "/api/session" }, -> { api_post "/api/session", { language: "es" } },
        -> { post "/api/session", headers: { "Origin" => origin } } ].each do |request|
        expect(&request).not_to change(Visitor, :count)
        expect(response).to have_http_status(:forbidden)
        expect(json).to eq("error" => "challenge")
        expect(response.headers["Set-Cookie"]).to be_nil
      end
      expect(Conversation.count).to eq 0
      expect(a_request(:post, TurnstileStubs::SITEVERIFY)).not_to have_been_made
    end

    it "refuses a token Cloudflare refuses, creating nothing and setting no cookie" do
      stub_siteverify_answer(TurnstileStubs::REFUSED)

      expect { api_post "/api/session", { turnstile_token: "0.a-token-cloudflare-refuses" } }.not_to change(Visitor, :count)

      expect(response).to have_http_status(:forbidden)
      expect(json).to eq("error" => "challenge")
      expect(response.headers["Set-Cookie"]).to be_nil
      expect(a_request(:post, TurnstileStubs::SITEVERIFY)).to have_been_made.once
    end

    it "refuses when siteverify does not answer in time, creating nothing" do
      stub_request(:post, TurnstileStubs::SITEVERIFY).to_timeout

      expect { api_post "/api/session", minting }.not_to change(Visitor, :count)
      expect(response).to have_http_status(:forbidden)
      expect(json).to eq("error" => "challenge")
    end

    it "mints with the test keys' token, which the suite's siteverify passes as Cloudflare does" do
      expect { api_post "/api/session", minting }.to change(Visitor, :count).by(1)

      expect(response).to have_http_status(:created)
      expect(a_request(:post, TurnstileStubs::SITEVERIFY)
        .with(body: { secret: TurnstileStubs::TEST_SECRET, response: TurnstileStubs::DUMMY_TOKEN }.to_json)).to have_been_made.once
    end

    it "needs no token from a page that brings back its cookie, and asks Cloudflare nothing, whatever the body carries" do
      visitor = start_session
      WebMock.reset!

      [ {}, { language: "es" }, { turnstile_token: "0.anything" } ].each do |body|
        expect { api_post "/api/session", body }.not_to change(Visitor, :count)
        expect(response).to have_http_status(:created)
        expect(cookie_visitor).to eq visitor
      end
      expect(a_request(:post, TurnstileStubs::SITEVERIFY)).not_to have_been_made
    end

    # A refused token and a minting one, each answered and each in the log's
    # lines (the fix review of pull request #53 found the refusal no longer
    # ran here once the stub said yes to any token).
    it "keeps the token out of the answer and of the log, refused or minting" do
      log = StringIO.new
      logger = ActiveSupport::Logger.new(log)
      allow(Rails).to receive(:logger).and_return(logger)
      token = "0.a-token-of-the-visitor"

      stub_siteverify_answer(TurnstileStubs::REFUSED)
      api_post "/api/session", { turnstile_token: token }
      expect(json).to eq("error" => "challenge")
      expect(log.string).to include("turnstile: refused: invalid-input-response")
      stub_siteverify
      api_post "/api/session", minting
      expect(response).to have_http_status(:created)

      expect(response.body).not_to include(TurnstileStubs::DUMMY_TOKEN)
      expect(log.string).not_to include(token)
      expect(log.string).not_to include(TurnstileStubs::DUMMY_TOKEN)
      expect(log.string).not_to include(TurnstileStubs::TEST_SECRET)
    end
  end

  describe "SR-03 Origin" do
    [ nil, "https://evil.example", "null", "http://127.0.0.1:3000" ].each do |bad|
      it "refuses a request from #{bad.inspect}, creating nothing and setting no cookie" do
        headers = { "Content-Type" => "application/json" }
        headers["Origin"] = bad if bad

        expect { post "/api/session", params: "{}", headers: }.not_to change(Visitor, :count)
        expect(response).to have_http_status(:forbidden)
        expect(json).to eq("error" => "origin")
        expect(response.headers["Set-Cookie"]).to be_nil
      end
    end
  end
end
