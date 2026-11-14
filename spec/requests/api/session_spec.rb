require "rails_helper"

# FR-18's MVP note: until Turnstile ships after the MVP, POST /api/session is
# gated by the per-IP limits alone (spec/requests/rate_limits_spec.rb).
RSpec.describe "FR-18 SR-03 POST /api/session issues the visitor cookie", type: :request do
  it "sets an HttpOnly, SameSite=Strict cookie and answers the open conversation, its trace token and language" do
    expect { api_post "/api/session" }.to change(Visitor, :count).by(1).and change(Conversation, :count).by(1)

    expect(response).to have_http_status(:created)
    conversation = Conversation.sole
    expect(json).to eq("conversation_id" => conversation.id, "trace_token" => conversation.trace_token, "language" => "pt-BR",
                       "mode" => "normal", "brl" => { "per_usd" => 5.6518, "verified_on" => "2026-11-13" })
    cookie = response.headers["Set-Cookie"]
    expect(cookie).to match(/\A#{WebSession::COOKIE}=/o)
    expect(cookie).to include("httponly").and include("samesite=strict").and include("path=/")
    expect(cookie_visitor).to eq conversation.visitor
    expect(conversation.visitor).to have_attributes(channel: "web")
  end

  # The glass box's head shows the budget's mode, and its costs in reais
  # beside the dollars (FR-12, FR-14; design §10, note of 2026-11-12).
  it "answers the month's budget mode and the rate of the real with its date" do
    api_post "/api/session"

    expect(json).to include("mode" => "normal", "brl" => { "per_usd" => 5.6518, "verified_on" => "2026-11-13" })

    BudgetState.for_month!.update!(forced_mode: "paused")
    api_post "/api/session"

    expect(json["mode"]).to eq("paused")
  end

  it "marks the cookie Secure over HTTPS, as production always is" do
    https!
    api_post "/api/session", {}, headers: { "Origin" => origin }

    expect(response.headers["Set-Cookie"]).to include("secure")
  end

  it "keeps the visitor's token out of the body and of every header but Set-Cookie (no token in a header)" do
    api_post "/api/session"

    expect(cookie_token).to match(/\A[1-9A-HJ-NP-Za-km-z]{24}\z/)
    expect(response.body).not_to include(cookie_token)
    expect(response.headers.except("Set-Cookie").values.join).not_to include(cookie_token)
  end

  it "stores the SHA-256 of the token, never the token" do
    api_post "/api/session"

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
      api_post "/api/session", { language: }

      expect(response).to have_http_status(:created)
      expect(json["language"]).to eq "pt-BR"
    end
  end

  it "mints a new visitor for a cookie whose signature does not verify" do
    cookies[WebSession::COOKIE.to_s] = "forged-token"

    expect { api_post "/api/session" }.to change(Visitor, :count).by(1)
    expect(cookie_visitor).to be_present
  end

  it "starts over with the same token after the visitor deleted its data (FR-05)" do
    visitor = start_session
    identity = visitor.identity_hash
    visitor.erase!

    expect { api_post "/api/session" }.to change(Visitor, :count).by(1)
    expect(Visitor.sole.identity_hash).to eq identity
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
