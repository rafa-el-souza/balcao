require "rails_helper"

# The Telegram delivery watch (design §9.2's M3 list, FR-19; the owner,
# 2026-11-15 and 2026-11-21): every ten minutes, beside FR-17's canary, a job
# reads getWebhookInfo and tells the monitor's heartbeat of its own that all
# is well, or fails it on a delivery error newer than its last look, a
# backlog of updates waiting, or a webhook Telegram holds otherwise than the
# bot's task set it. getWebhookInfo has no secret field, so a secret changed
# on the server without the task run shows only as delivery errors, which is
# what this sees. On a rehearsal host, with no monitor URL, it looks at
# nothing.
RSpec.describe "FR-19 FR-17 NFR-04 the Telegram delivery watch" do
  include TelegramBotApi

  let(:monitor) { "https://monitor.example/api/v1/heartbeat/telegram-token-of-the-specs" }
  let(:healthy) do
    { "url" => "#{Rails.configuration.x.public_origin}/webhooks/telegram", "has_custom_certificate" => false,
      "pending_update_count" => 0, "max_connections" => 1, "allowed_updates" => [ "message" ] }
  end
  let(:info) { healthy }
  let!(:asked) { stub_request(:post, bot_api_url("getWebhookInfo")).to_return { bot_api_answer(info) } }
  let!(:beat) { stub_request(:post, monitor).to_return(status: 200) }
  let!(:failure) { stub_request(:post, "#{monitor}/fail").to_return(status: 200) }
  let(:cache) { ActiveSupport::Cache::MemoryStore.new }
  let(:now) { Time.zone.local(2026, 11, 21, 10, 0) }

  around do |example|
    saved = Rails.configuration.x.telegram_monitor_url
    Rails.configuration.x.telegram_monitor_url = monitor
    travel_to(now) { example.run }
  ensure
    Rails.configuration.x.telegram_monitor_url = saved
  end

  before do
    allow(Rails.logger).to receive(:info).and_call_original
    allow(Rails.logger).to receive(:error).and_call_original
  end

  def look = Telegram::Watch.new(cache:).call

  def failed_with(reason) = failure.with(body: "telegram: #{reason}")

  it "tells the monitor all is well when Telegram delivers, with nothing waiting" do
    expect(look).to eq([])
    expect(asked).to have_been_requested.once
    expect(beat).to have_been_requested.once
    expect(failure).not_to have_been_requested
    expect(Rails.logger).to have_received(:info).with("telegram watch: the webhook delivers, 0 updates waiting")
  end

  describe "a delivery error" do
    let(:error_at) { 9.minutes.ago.to_i }
    let(:info) { healthy.merge("last_error_date" => error_at, "last_error_message" => "Wrong response from the webhook: 401 Unauthorized") }

    it "newer than the last one the monitor took fails the heartbeat, with Telegram's words and the error's time" do
      cache.write(Telegram::Watch::TOLD, error_at - 60)

      problems = look

      expect(problems).to eq([ "a delivery error at 2026-11-21T12:51:00Z: Wrong response from the webhook: 401 Unauthorized" ])
      expect(failed_with(problems.first)).to have_been_requested.once
      expect(beat).not_to have_been_requested
      expect(Rails.logger).to have_received(:error).with("telegram watch: #{problems.first}")
    end

    it "already taken by the monitor is not told again once the updates drained" do
      cache.write(Telegram::Watch::TOLD, error_at)
      cache.write(Telegram::Watch::DRAINED, error_at)

      expect(look).to eq([])
      expect(beat).to have_been_requested.once
    end

    it "with nothing told yet (a first run, a cache that lost it), counts when it is newer than the watch's interval" do
      expect(look.size).to eq(1)
    end

    it "keeps Telegram's own date of the error the monitor took, never the host's clock" do
      look

      expect(cache.read(Telegram::Watch::TOLD)).to eq(error_at)
    end

    # C4 = H12 of #64's review: a /fail the monitor did not take leaves the
    # error untold, so the next look tells it again.
    it "is told again when the monitor did not take it" do
      stub_request(:post, "#{monitor}/fail").to_return({ status: 503 }, { status: 200 })

      2.times { look }

      expect(a_request(:post, "#{monitor}/fail")).to have_been_made.twice
      expect(cache.read(Telegram::Watch::TOLD)).to eq(error_at)
    end

    # H3 of #64's review: Telegram tries a failed update again in its own
    # time, so between its tries the date stays and the updates wait; the
    # watch fails until they drain, not only at a newer error.
    it "keeps failing the heartbeat while updates wait after it, until they drain" do
      cache.write(Telegram::Watch::TOLD, error_at)
      cache.write(Telegram::Watch::DRAINED, error_at - 3_600)
      info.merge!("pending_update_count" => 2)

      expect(look).to eq([ "2 updates waiting since a delivery error at 2026-11-21T12:51:00Z: Wrong response from the webhook: 401 Unauthorized" ])

      info.merge!("pending_update_count" => 0)

      expect(look).to eq([])
      expect(cache.read(Telegram::Watch::DRAINED)).to eq(error_at)
    end
  end

  it "with nothing told yet, leaves an error older than the watch's interval to the earlier looks" do
    info.merge!("last_error_date" => 20.minutes.ago.to_i, "last_error_message" => "Connection timed out")

    expect(look).to eq([])
  end

  it "cuts Telegram's words to a line's worth" do
    info.merge!("last_error_date" => 1.minute.ago.to_i, "last_error_message" => "x" * 1_000)

    expect(look.first.length).to be <= 300
  end

  it "fails the heartbeat on a backlog of updates waiting" do
    info.merge!("pending_update_count" => Telegram::Watch::BACKLOG)

    expect(look).to eq([ "#{Telegram::Watch::BACKLOG} updates waiting" ])
    expect(failed_with("#{Telegram::Watch::BACKLOG} updates waiting")).to have_been_requested.once
  end

  it "takes a few updates waiting as Telegram at work: it sends one at a time" do
    info.merge!("pending_update_count" => Telegram::Watch::BACKLOG - 1)

    expect(look).to eq([])
  end

  it "fails the heartbeat when the webhook is gone or differs from what the bot's task sets" do
    info.merge!("url" => "", "max_connections" => 40)

    expect(look).to eq([ "the webhook's url and max_connections differ from what the bot's task sets" ])
  end

  # C5 and V2 of #64's review: a refusal is named by Telegram's code alone,
  # never its description, as every other caller of the client logs it
  # (threat model SR-30).
  it "fails the heartbeat when Telegram refuses the call, naming Telegram's code alone" do
    stub_request(:post, bot_api_url("getWebhookInfo")).to_return(bot_api_error(400, "Bad Request: words of no one"))

    expect(look).to eq([ "getWebhookInfo failed: 400" ])
    expect(beat).not_to have_been_requested
    expect(Rails.logger).not_to have_received(:error).with(/words of no one/)
    expect(a_request(:post, "#{monitor}/fail").with(body: /words of no one/)).not_to have_been_made
  end

  it "tells nothing as told when Telegram does not answer, so an error from before is told at the next look" do
    cache.write(Telegram::Watch::TOLD, 30.minutes.ago.to_i)
    stub_request(:post, bot_api_url("getWebhookInfo")).to_return(bot_api_error(502, "Bad Gateway"))
      .then.to_return(bot_api_answer(info.merge("last_error_date" => 8.minutes.ago.to_i, "last_error_message" => "Read timeout expired")))

    expect(look).to eq([ "getWebhookInfo failed: HTTP 502" ])
    expect(look).to eq([ "a delivery error at 2026-11-21T12:52:00Z: Read timeout expired" ])
  end

  it "fails the heartbeat when the way to Telegram breaks, naming the failure's class" do
    stub_request(:post, bot_api_url("getWebhookInfo")).to_timeout

    expect(look).to eq([ "getWebhookInfo failed: Net::OpenTimeout" ])
  end

  it "looks all the same when the cache breaks, as on a first run" do
    broken = instance_double(ActiveSupport::Cache::Store)
    allow(broken).to receive(:read).and_raise(ActiveRecord::ConnectionFailed, "gone")
    allow(broken).to receive(:write).and_raise(ActiveRecord::ConnectionFailed, "gone")

    expect(Telegram::Watch.new(cache: broken).call).to eq([])
    expect(beat).to have_been_requested.once
  end

  # A rehearsal host has no monitor and a bot of its own with no webhook
  # (design §8): the watch asks Telegram nothing there.
  it "looks at nothing with no monitor URL" do
    Rails.configuration.x.telegram_monitor_url = nil

    expect(look).to be_nil
    expect(asked).not_to have_been_requested
  end

  it "runs in its job, which a failure never makes try again" do
    allow(Telegram::Watch).to receive(:new).and_raise(ActiveRecord::ConnectionFailed, "gone")

    expect { TelegramWatchJob.perform_now }.not_to raise_error
    expect(failed_with("not looked, ActiveRecord::ConnectionFailed")).to have_been_requested.once
    expect(Rails.logger).to have_received(:error).with(%r{\Atelegram watch: not looked, ActiveRecord::ConnectionFailed\n.*app/jobs/telegram_watch_job\.rb:\d+}m)
  end
end

# C2 = H13 of #64's review: Telegram dates an error in whole seconds, and a
# look is not an instant; the watch keeps Telegram's own date of what it
# told, so the host's fraction of a second and its clock decide nothing.
RSpec.describe "FR-19 the Telegram delivery watch, on Telegram's clock" do
  include TelegramBotApi

  let(:monitor) { "https://monitor.example/api/v1/heartbeat/telegram-token-of-the-specs" }
  let(:info) do
    { "url" => "#{Rails.configuration.x.public_origin}/webhooks/telegram", "has_custom_certificate" => false,
      "pending_update_count" => 0, "max_connections" => 1, "allowed_updates" => [ "message" ] }
  end
  let(:cache) { ActiveSupport::Cache::MemoryStore.new }
  let(:start) { Time.zone.local(2026, 11, 21, 10, 0, 0) + 0.2 }

  around do |example|
    saved = Rails.configuration.x.telegram_monitor_url
    Rails.configuration.x.telegram_monitor_url = monitor
    example.run
  ensure
    Rails.configuration.x.telegram_monitor_url = saved
  end

  before do
    stub_request(:post, bot_api_url("getWebhookInfo")).to_return { bot_api_answer(info) }
    stub_request(:post, monitor).to_return(status: 200)
    stub_request(:post, "#{monitor}/fail").to_return(status: 200)
  end

  def look(at) = travel_to(at, with_usec: true) { Telegram::Watch.new(cache:).call }

  it "tells once an error dated during a look's own request" do
    info.merge!("last_error_date" => (start + 0.8).to_i, "last_error_message" => "Read timeout expired")

    expect(look(start).size).to eq(1)
    expect(look(start + 10.minutes)).to eq([])
  end

  it "tells an error dated in the same second as the look before it, after Telegram answered that look" do
    expect(look(start)).to eq([])

    info.merge!("last_error_date" => start.to_i, "last_error_message" => "Read timeout expired")

    expect(look(start + 10.minutes).size).to eq(1)
  end
end
