require "rails_helper"

# The external monitor's heartbeats (FR-17, NFR-04, design §8): a request to
# the heartbeat's URL says all is well, one to the same URL with /fail says it
# is not, with a short text the monitor shows beside its incident, and the
# monitor alerts on a failure and on silence. The URL carries the monitor's
# token, so no line names it (threat model SR-30), and a heartbeat that cannot
# be sent never fails its caller: the monitor hears silence instead.
RSpec.describe "FR-17 NFR-04 SR-30 the monitor's heartbeats" do
  let(:url) { "https://monitor.example/api/v1/heartbeat/token-of-the-specs" }
  let(:heartbeat) { Heartbeat.new(url, name: "canary") }

  before { allow(Rails.logger).to receive(:error) }

  it "says all is well with a request to its URL" do
    sent = stub_request(:post, url).to_return(status: 200)

    expect(heartbeat.beat).to be(true)
    expect(sent).to have_been_requested.once
  end

  it "says a failure with a request to its URL and /fail, carrying the reason as text" do
    sent = stub_request(:post, "#{url}/fail").with(body: "the reply lacks the marker", headers: { "Content-Type" => "text/plain; charset=utf-8" })
                                              .to_return(status: 200)

    expect(heartbeat.failure("the reply lacks the marker")).to be(true)
    expect(sent).to have_been_requested.once
  end

  it "appends /fail to a URL that ends with a slash without doubling it" do
    sent = stub_request(:post, "#{url}/fail").to_return(status: 200)

    expect(Heartbeat.new("#{url}/", name: "canary").failure("x")).to be(true)
    expect(sent).to have_been_requested.once
  end

  # H4 = C3s of #64's review: /fail joins the URL's path, so a query or a
  # fragment can never carry it to the success endpoint.
  it "joins /fail to the URL's path, never to its query, so a failure never reaches the success endpoint" do
    ok = stub_request(:post, "https://monitor.example/hb/token").with(query: hash_including({})).to_return(status: 200)
    sent = stub_request(:post, "https://monitor.example/hb/token/fail?src=x").to_return(status: 200)

    expect(Heartbeat.new("https://monitor.example/hb/token?src=x", name: "canary").failure("r")).to be(true)
    expect(sent).to have_been_requested.once
    expect(ok).not_to have_been_requested
  end

  it "cuts a long reason to what a monitor shows" do
    sent = stub_request(:post, "#{url}/fail").with { |request| request.body.length == Heartbeat::MAX_REASON }.to_return(status: 200)

    heartbeat.failure("x" * (Heartbeat::MAX_REASON * 2))

    expect(sent).to have_been_requested.once
  end

  it "answers false, with a line naming the status and never the URL, when the monitor refuses it" do
    stub_request(:post, url).to_return(status: 404)

    expect(heartbeat.beat).to be(false)
    expect(Rails.logger).to have_received(:error).with("heartbeat canary: the monitor answered HTTP 404")
    expect(Rails.logger).not_to have_received(:error).with(a_string_including("token-of-the-specs"))
  end

  it "follows no redirect: an answer of 3xx is a refusal" do
    stub_request(:post, url).to_return(status: 301, headers: { "Location" => "https://elsewhere.example/" })

    expect(heartbeat.beat).to be(false)
    expect(Rails.logger).to have_received(:error).with("heartbeat canary: the monitor answered HTTP 301")
  end

  it "answers false, with a line naming the error's class alone, when the network fails" do
    stub_request(:post, url).to_raise(SocketError.new("Failed to open TCP connection to monitor.example:443 (token-of-the-specs)"))

    expect(heartbeat.beat).to be(false)
    expect(Rails.logger).to have_received(:error).with("heartbeat canary: not sent, SocketError")
  end

  it "answers false on a timeout, which its short timeouts bound" do
    stub_request(:post, url).to_timeout

    expect(heartbeat.beat).to be(false)
    expect(Rails.logger).to have_received(:error).with(/\Aheartbeat canary: not sent, Net::OpenTimeout\z/)
    expect([ Heartbeat::OPEN_TIMEOUT, Heartbeat::READ_TIMEOUT ]).to all(be <= 5)
  end

  it "sends nothing to a URL that is not https, and says so without naming it" do
    plain = Heartbeat.new("http://monitor.example/api/v1/heartbeat/token-of-the-specs", name: "canary")

    expect(plain.beat).to be(false)
    expect(Rails.logger).to have_received(:error).with("heartbeat canary: the monitor's URL is not https, not sent")
    expect(a_request(:any, /monitor\.example/)).not_to have_been_made
  end

  # A rehearsal host has no monitor (design §8): its heartbeats send nothing
  # and say nothing.
  it "sends nothing when it has no URL" do
    blank = Heartbeat.new(nil, name: "canary")

    expect(blank).not_to be_configured
    expect(blank.beat).to be(false)
    expect(blank.failure("x")).to be(false)
    expect(Rails.logger).not_to have_received(:error)
  end

  it "reads the canary's URL and the Telegram watch's from the configuration" do
    saved = [ Rails.configuration.x.monitor_url, Rails.configuration.x.telegram_monitor_url ]
    Rails.configuration.x.monitor_url = "https://monitor.example/a"
    Rails.configuration.x.telegram_monitor_url = "https://monitor.example/b"
    canary = stub_request(:post, "https://monitor.example/a").to_return(status: 200)
    watch = stub_request(:post, "https://monitor.example/b").to_return(status: 200)

    expect([ Heartbeat.canary.beat, Heartbeat.telegram.beat ]).to eq([ true, true ])
    expect([ canary, watch ]).to all(have_been_requested.once)
  ensure
    Rails.configuration.x.monitor_url, Rails.configuration.x.telegram_monitor_url = saved
  end
end
