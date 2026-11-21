require "json"
require "net/http"
require "openssl"
require "uri"
require_relative "catalogue"

# Threat model SR-03 seen from outside (design §9.2's M3 list, M3-6): a
# deployed host is asked, through its proxy and Thruster, for a page of each
# kind and for every answer of the catalogue one request can reach, and each
# answer is read for the set the application writes on every answer (the
# policy, nosniff, the frame, referrer and permissions headers, HSTS over
# HTTPS, no X-Runtime). It shows what kamal-proxy or Thruster add, remove or
# answer by themselves, which no test inside the process can see; the
# proxy's own answers are read for their accepted shape instead. Plain Ruby,
# no Rails: bin/edge-check runs it from the development account against a
# rehearsal host, never in the operator account (SR-38).
module EdgeCheck
  # The headers every answer the application writes carries (SR-03).
  SET = %w[content-security-policy x-content-type-options x-frame-options referrer-policy permissions-policy].freeze
  # What no answer may say: how long the server took.
  NEVER = %w[x-runtime].freeze
  # The trace page passes no referrer on, since its link is a credential
  # (SR-11): the one header of the set an answer writes itself.
  OWN = { "a trace's page" => { "referrer-policy" => "no-referrer" } }.freeze
  # A marker in a path, which no page of the proxy's may give back.
  MARKER = "edge-check-marker".freeze

  Probe = Data.define(:label, :method, :path, :headers, :body, :status, :scheme, :kind) do
    def self.app(label, path, status, method: "GET", headers: {}, body: nil, kind: :app)
      new(label:, method:, path:, headers:, body:, status:, scheme: "https", kind:)
    end
  end
  Answer = Data.define(:status, :headers, :body)

  WEBSOCKET = { "Upgrade" => "websocket", "Connection" => "Upgrade" }.freeze

  def self.probes(host)
    origin = { "Origin" => "https://#{host}", "Content-Type" => "application/json" }
    [
      Probe.app("the health check", "/up", 200),
      Probe.app("the landing", "/", 200),
      Probe.app("the chat's page", "/chat", 200),
      Probe.app("the privacy page", "/privacy", 200),
      Probe.app("a trace's page", "/trace", 200),
      Probe.app("the API without a session", "/api/conversations/current", 401),
      Probe.app("a session asked for without Turnstile's token", "/api/session", 403, method: "POST", headers: origin, body: "{}"),
      Probe.app("an unknown path", "/no-such-page", 404),
      Probe.app("a route's constraint not met", "/trace/abc", 404),
      Probe.app("a static file", "/robots.txt", 200),
      Probe.app("a body over 16 KB", "/api/messages", 413, method: "POST", headers: origin, body: "x" * 20_000),
      Probe.app("the cable's handshake of another version", "/cable", 426,
                headers: WEBSOCKET.merge("Origin" => "https://#{host}", "Sec-WebSocket-Version" => "12")),
      Probe.app("the cable's handshake without a key", "/cable", 400,
                headers: WEBSOCKET.merge("Origin" => "https://#{host}", "Sec-WebSocket-Version" => "13")),
      Probe.new(label: "the proxy's redirect to HTTPS", method: "GET", path: "/#{MARKER}", headers: {}, body: nil,
                status: EDGE.fetch("the proxy's redirect to HTTPS"), scheme: "http", kind: :redirect),
      Probe.new(label: "the proxy's page for a host it does not serve", method: "GET", path: "/#{MARKER}?q=#{MARKER}",
                headers: { "Host" => "elsewhere.example" }, body: nil,
                status: EDGE.fetch("the proxy's page for a host it does not serve"), scheme: "https", kind: :proxy_page)
    ]
  end

  # The catalogue's labels a probe asks of the application by that name.
  def self.asked(host) = probes(host).map(&:label) & CATALOGUE.keys

  class Check
    # The edge's limit on requests without a session: past this many in a
    # minute the next is refused (FR-14's 60, and a margin).
    LIMIT_TRIES = 70

    def initialize(origin, out: $stdout, requester: nil)
      uri = URI(origin)
      raise ArgumentError, "give the host's https origin, as https://ensaio.rafasouza.dev.br" unless uri.is_a?(URI::HTTPS) && uri.path.to_s.delete("/").empty?

      @host = uri.host
      @out = out
      @requester = requester || method(:request)
      @failures = []
    end

    # Asks every probe, then the edge's limit, and answers whether all held.
    def run
      answers = EdgeCheck.probes(@host).to_h { |probe| [ probe, @requester.call(@host, probe) ] }
      policy = answers.find { |probe, _| probe.label == "the health check" }&.last&.headers&.fetch("content-security-policy", nil)
      answers.each { |probe, answer| judge(probe, answer, policy) }
      judge_limit(policy)
      INSIDE_ONLY.each { |label| @out.puts "-    #{label}: inside only (spec/requests/response_headers_spec.rb)" }
      ACCEPTED.each { |label| @out.puts "-    #{label}: accepted without the set, not asked (threat model SR-03)" }
      extras(answers)
      @out.puts(@failures.empty? ? "edge-check: every answer held" : "edge-check: #{@failures.size} failed")
      @failures.empty?
    end

    private

    def judge(probe, answer, policy)
      problems = []
      problems << "status #{answer.status}, not #{probe.status}" unless answer.status == probe.status
      problems.concat(
        case probe.kind
        when :app then set_problems(probe, answer, policy)
        when :redirect then redirect_problems(probe, answer)
        else proxy_page_problems(answer)
        end
      )
      report(probe.label, answer.status, problems)
    end

    def set_problems(probe, answer, policy)
      headers = answer.headers
      problems = (SET - headers.keys).map { |name| "no #{name}" }
      problems << "a policy other than /up's" if policy.nil? || (headers.key?("content-security-policy") && headers["content-security-policy"] != policy)
      problems << "no nosniff" if headers.key?("x-content-type-options") && headers["x-content-type-options"] != "nosniff"
      problems << "no strict-transport-security" unless headers.key?("strict-transport-security")
      problems.concat((NEVER & headers.keys).map { |name| "#{name} says too much" })
      OWN.fetch(probe.label, {}).each { |name, value| problems << "#{name} not #{value}" unless headers[name] == value }
      problems
    end

    def redirect_problems(probe, answer)
      location = answer.headers["location"]
      location == "https://#{@host}#{probe.path}" ? [] : [ "location #{location.inspect}, not the same path over HTTPS" ]
    end

    def proxy_page_problems(answer)
      answer.body.to_s.include?(MARKER) ? [ "the page gives back the request's path or query" ] : []
    end

    def judge_limit(policy)
      probe = Probe.app("a request past the edge's limit", "/api/conversations/current", CATALOGUE.fetch("a request past the edge's limit"))
      answer = nil
      LIMIT_TRIES.times do
        answer = @requester.call(@host, probe)
        break if answer.status == probe.status
      end
      problems = answer.status == probe.status ? set_problems(probe, answer, policy) : [ "no 429 in #{LIMIT_TRIES} requests" ]
      report(probe.label, answer.status, problems)
    end

    def report(label, status, problems)
      if problems.empty?
        @out.puts "ok   #{label}: #{status}"
      else
        @failures << label
        @out.puts "FAIL #{label}: #{problems.join("; ")}"
      end
    end

    # The headers past the application's set on each kind of answer: what the
    # proxy and Thruster add, for the person running the check to read.
    def extras(answers)
      names = answers.select { |probe, _| probe.kind == :app }.values.flat_map { |answer| answer.headers.keys }.uniq.sort
      @out.puts "headers on the application's answers, beside the set: #{(names - SET).join(", ")}"
    end

    def request(host, probe)
      uri = URI("#{probe.scheme}://#{host}#{probe.path}")
      http = Net::HTTP.new(host, uri.port)
      http.use_ssl = probe.scheme == "https"
      http.open_timeout = http.read_timeout = 10
      request = Net::HTTPGenericRequest.new(probe.method, !probe.body.nil?, true, uri.request_uri, probe.headers)
      request.body = probe.body if probe.body
      response = http.start { |connection| connection.request(request) }
      Answer.new(status: response.code.to_i, headers: response.each_header.to_h, body: response.body)
    end
  end
end
