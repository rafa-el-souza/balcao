require "net/http"

# The external monitor's heartbeats (FR-17, NFR-04, design §8): a request to a
# heartbeat's URL says all is well, one to the same URL with /fail says it is
# not, with a short text the monitor shows beside its incident; the monitor
# alerts on a failure, and on silence when no request comes within its
# period and grace, so a worker that stopped is heard too. Two heartbeats,
# each with its own incident (the owner, 2026-11-21, "Dois heartbeats"): the
# canary's (MONITOR_URL) and the Telegram delivery watch's
# (TELEGRAM_MONITOR_URL), since a request on time resolves the incident a
# /fail opened, and the canary's would close the watch's.
#
# The URL carries the monitor's token, so no line names it, nor any error's
# message, which may quote the host and the path: a line names the heartbeat
# by its role, and the monitor's status or the error's class (threat model
# SR-30). HTTPS alone, short timeouts, no redirect followed (an answer of 3xx
# is a refusal). A heartbeat that cannot be sent never fails its caller: one
# line, and the monitor hears silence. A rehearsal host has no URL (design
# §8): nothing is sent, and nothing said.
class Heartbeat
  OPEN_TIMEOUT = 5
  READ_TIMEOUT = 5
  # What a monitor shows beside an incident: a line, not a log.
  MAX_REASON = 300

  def self.canary = new(Rails.configuration.x.monitor_url, name: "canary")

  def self.telegram = new(Rails.configuration.x.telegram_monitor_url, name: "telegram watch")

  def initialize(url, name:)
    @url = url.to_s.strip.presence
    @name = name
  end

  def configured? = !@url.nil?

  # All is well: true when the monitor took it.
  def beat = ping(@url, "")

  # A failure, with its reason as text: true when the monitor took it.
  def failure(reason) = ping(failure_url, reason.to_s.first(MAX_REASON))

  private

  def failure_url = @url && "#{@url.chomp("/")}/fail"

  def ping(url, body)
    return false unless configured?

    uri = URI.parse(url)
    return refused("the monitor's URL is not https, not sent") unless uri.is_a?(URI::HTTPS) && uri.host.present?

    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT,
                                                   write_timeout: READ_TIMEOUT) do |http|
      http.post(uri.request_uri, body, "content-type" => "text/plain; charset=utf-8")
    end
    return true if response.is_a?(Net::HTTPSuccess)

    refused("the monitor answered HTTP #{response.code}")
  rescue StandardError => e
    refused("not sent, #{e.class}")
  end

  def refused(why)
    Rails.logger.error("heartbeat #{@name}: #{why}")
    false
  end
end
