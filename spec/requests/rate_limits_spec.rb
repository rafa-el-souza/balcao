require "rails_helper"

# FR-14's per-visitor caps and per-IP limits (the scenario that is their only
# home) and threat model SR-01, SR-36: counted at the edge by Rack::Attack, in
# rolling windows from the first counted event (design §1.4); an over-limit
# request gets a fixed reply, no model call and nothing stored beyond the
# counter.
RSpec.describe "FR-14 SR-01 SR-36 per-IP and per-visitor limits", type: :request do
  include ActiveJob::TestHelper

  around do |example|
    store = Rack::Attack.cache.store
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
    travel_to(Time.zone.local(2026, 11, 11, 14, 30, 30)) { example.run }
  ensure
    Rack::Attack.cache.store = store
  end

  def from(ip) = { "REMOTE_ADDR" => ip }

  def session_from(ip)
    post "/api/session", params: "{}", headers: { "Content-Type" => "application/json", "Origin" => origin }, env: from(ip)
  end

  def message_from(ip, text = "oi")
    post "/api/messages", params: { id: SecureRandom.uuid, text: }.to_json,
                          headers: { "Content-Type" => "application/json", "Origin" => origin }, env: from(ip)
  end

  def poll_from(ip, headers: {}) = get("/api/conversations/current", headers:, env: from(ip))

  def limited?(text_key = nil)
    response.status == 429 && json["error"] == "limit" && (text_key.nil? || json["text"] == I18n.t(text_key, locale: :"pt-BR"))
  end

  describe "one client IP" do
    it "refuses its 61st API request within a minute with the fixed reply, and counts from its first request" do
      60.times { poll_from("203.0.113.7") }
      expect(response).to have_http_status(:unauthorized)

      poll_from("203.0.113.7")
      expect(limited?("limits.now")).to be true

      travel 40.seconds # 14:31:10: a new minute on the clock, still the first request's minute
      poll_from("203.0.113.7")
      expect(limited?).to be true

      travel 21.seconds # 14:31:31
      poll_from("203.0.113.7")
      expect(response).to have_http_status(:unauthorized)
    end

    it "refuses its 21st new session within an hour, storing nothing" do
      20.times { session_from("203.0.113.7").then { cookies.delete(WebSession::COOKIE.to_s) } }
      expect(response).to have_http_status(:created)

      expect { session_from("203.0.113.7") }.not_to change(Visitor, :count)
      expect(limited?("limits.now")).to be true
    end

    it "does not count a page load whose cookie names a session already issued as a new session" do
      25.times do
        session_from("203.0.113.7")
        expect(response).to have_http_status(:created)
        travel 3.seconds
      end

      expect(Visitor.count).to eq 1
    end

    it "refuses its 201st turn within a day, with no turn stored and no job enqueued" do
      # Twenty visitors behind one address, ten turns each, each under its own
      # caps and the address under its per-minute and per-session limits.
      200.times do |n|
        if (n % 10).zero?
          travel 61.seconds
          cookies.delete(WebSession::COOKIE.to_s)
          session_from("203.0.113.7")
        end
        message_from("203.0.113.7")
        expect(response).to have_http_status(:accepted), "turn #{n + 1}: #{response.status}"
      end
      travel 61.seconds

      expect { message_from("203.0.113.7") }.not_to change(Message, :count)
      expect(limited?("limits.today")).to be true
      expect(enqueued_jobs.size).to eq 200
    end

    it "counts two addresses of one IPv6 /64 as one source, and another /64 apart" do
      30.times { poll_from("2001:db8:1:2::a") }
      30.times { poll_from("2001:db8:1:2:ffff:ffff:ffff:ffff") }

      poll_from("2001:db8:1:2::1")
      expect(limited?).to be true

      poll_from("2001:db8:1:3::1")
      expect(response).to have_http_status(:unauthorized)
    end

    it "counts an IPv4 address mapped into IPv6 as the IPv4 address" do
      60.times { poll_from("198.51.100.4") }

      poll_from("::ffff:198.51.100.4")
      expect(limited?).to be true
    end

    it "SR-36 takes the client address from the trusted proxy's header, and a forged one does not split the count" do
      60.times do |n|
        get "/api/conversations/current", env: from("172.18.0.2"),
                                          headers: { "X-Forwarded-For" => "198.51.100.#{n}, 203.0.113.9" }
      end

      get "/api/conversations/current", env: from("172.18.0.2"), headers: { "X-Forwarded-For" => "203.0.113.9" }
      expect(limited?).to be true

      get "/api/conversations/current", env: from("172.18.0.2"), headers: { "X-Forwarded-For" => "203.0.113.10" }
      expect(response).to have_http_status(:unauthorized)
    end

    it "answers in the page's language when it names one of the three" do
      61.times { poll_from("203.0.113.7", headers: { "Accept-Language" => "en-US,en;q=0.9" }) }

      expect(json["text"]).to eq I18n.t("limits.now", locale: :en)
    end

    it "never limits the health check, which the proxy and the monitor call" do
      70.times { get "/up", env: from("203.0.113.7") }

      expect(response).to have_http_status(:ok)
    end
  end

  # Review finding C2 of pull request #12: a hostile page can make its
  # visitors' browsers post here, with its own Origin and without the
  # SameSite=Strict cookie. The app refuses those requests; the edge must not
  # let them spend the limits of the address they come from.
  describe "requests a browser sends from another site" do
    # As a browser sends it: another site's Origin, and no SameSite=Strict
    # cookie, which rack-test would otherwise send.
    def cross_site(path)
      held = cookies[WebSession::COOKIE.to_s]
      cookies.delete(WebSession::COOKIE.to_s)
      post(path, params: "x", headers: { "Content-Type" => "text/plain", "Origin" => "https://evil.example" }, env: from("203.0.113.7"))
    ensure
      cookies[WebSession::COOKIE.to_s] = held if held
    end

    it "do not spend the address's turns" do
      200.times do |n|
        travel(61.seconds) if (n % 55).zero?
        cross_site("/api/messages")
      end
      expect(response).to have_http_status(:forbidden)

      travel 61.seconds
      session_from("203.0.113.7")
      message_from("203.0.113.7")
      expect(response).to have_http_status(:accepted)
    end

    it "do not count as minted sessions" do
      20.times { cross_site("/api/session") }

      session_from("203.0.113.7")
      expect(response).to have_http_status(:created)
    end

    it "do not use up the address's requests of the minute for the visitors who hold a cookie" do
      session_from("203.0.113.7")
      70.times { cross_site("/api/messages") }

      poll_from("203.0.113.7")
      expect(response).to have_http_status(:ok)
    end

    it "are limited on their own: the 61st anonymous request in a minute is refused" do
      60.times { cross_site("/api/messages") }
      expect(response).to have_http_status(:forbidden)

      cross_site("/api/messages")
      expect(limited?("limits.now")).to be true
    end
  end

  # Review finding C1 of pull request #12: the routes took a format
  # extension, which the edge did not count as a turn or a session.
  describe "a path with a format extension" do
    def json_post(path, body) = post(path, params: body.to_json, headers: { "Content-Type" => "application/json", "Origin" => origin },
                                                             env: from("203.0.113.7"))

    it "is never a turn: /api/messages.json stores nothing and enqueues no job" do
      session_from("203.0.113.7")

      expect { json_post("/api/messages.json", { id: SecureRandom.uuid, text: "oi" }) }.not_to change(Message, :count)
      expect(response).to have_http_status(:not_found)
      expect(enqueued_jobs).to be_empty
    end

    it "is never a session: /api/session.json mints none" do
      expect { json_post("/api/session.json", {}) }.not_to change(Visitor, :count)
      expect(response).to have_http_status(:not_found)
      expect(response.headers["Set-Cookie"]).to be_nil
    end

    it "is never a poll: /api/conversations/current.json answers nothing" do
      session_from("203.0.113.7")
      get "/api/conversations/current.json", env: from("203.0.113.7")

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "one visitor" do
    before { session_from("203.0.113.7") }

    it "refuses its 11th turn within a minute with 'por agora', storing nothing and calling no model" do
      10.times { message_from("203.0.113.7") }

      expect { message_from("203.0.113.8") }.not_to change(Message, :count)
      expect(limited?("limits.now")).to be true
      expect(enqueued_jobs.size).to eq 10
    end

    it "refuses its 41st turn within 24 hours with 'por hoje', and counts from its first turn" do
      40.times { message_from("203.0.113.7").then { travel 2.minutes } }

      message_from("203.0.113.7")
      expect(limited?("limits.today")).to be true

      travel_to Time.zone.local(2026, 11, 12, 14, 30, 29)
      message_from("203.0.113.7")
      expect(limited?).to be true

      travel 2.seconds
      message_from("203.0.113.7")
      expect(response).to have_http_status(:accepted)
    end

    it "FR-05 keeps counting after the visitor deleted its data: the counter is not in the deleted rows" do
      10.times { message_from("203.0.113.7") }
      Visitor.sole.erase!

      message_from("203.0.113.7")
      expect(limited?("limits.now")).to be true
    end
  end
end
