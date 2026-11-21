require "rails_helper"
require_relative "../../lib/edge_check/check"

# Threat model SR-03 seen from outside (design §9.2's M3 list, M3-6):
# bin/edge-check asks a deployed host for the catalogue of
# spec/requests/response_headers_spec.rb through its proxy. Here its reading
# of the answers, with a stand-in for the network.
RSpec.describe "SR-03 bin/edge-check reads a deployed host's answers from outside" do
  let(:host) { "ensaio.example" }
  let(:policy) { "default-src 'self'; frame-ancestors 'none'" }
  let(:set) do
    { "content-security-policy" => policy, "x-content-type-options" => "nosniff", "x-frame-options" => "SAMEORIGIN",
      "referrer-policy" => "strict-origin-when-cross-origin", "permissions-policy" => "camera=()",
      "strict-transport-security" => "max-age=63072000; includeSubDomains", "x-cache" => "miss" }
  end
  let(:out) { StringIO.new }
  let(:asked) { [] }
  let(:overrides) { {} }
  let(:limit_after) { 3 }

  # Answers as the demo answered from outside on 2026-11-21: the
  # application's answers with the set, the proxy's own without it.
  def answer_for(probe)
    asked << probe.label
    return overrides.fetch(probe.label).call(probe) if overrides.key?(probe.label)

    case probe.kind
    when :redirect
      EdgeCheck::Answer.new(status: 301, headers: { "location" => "https://#{host}#{probe.path}" }, body: "")
    when :proxy_page
      EdgeCheck::Answer.new(status: 404, headers: { "content-type" => "text/html" }, body: "<title>404 — Not Found</title>")
    else
      if probe.label == "a request past the edge's limit"
        status = asked.count(probe.label) > limit_after ? 429 : 401
        EdgeCheck::Answer.new(status:, headers: set, body: "")
      else
        headers = probe.label == "a trace's page" ? set.merge("referrer-policy" => "no-referrer") : set
        EdgeCheck::Answer.new(status: probe.status, headers:, body: "")
      end
    end
  end

  def run = EdgeCheck::Check.new("https://#{host}", out:, requester: ->(_host, probe) { answer_for(probe) }).run

  it "passes a host whose every answer holds, asking the proxy's own two answers and the edge's limit" do
    expect(run).to be true
    expect(out.string).to include("edge-check: every answer held", "ok   the proxy's redirect to HTTPS: 301",
                                  "ok   a request past the edge's limit: 429", "inside only", "beside the set: strict-transport-security, x-cache")
    expect(asked).to include("the proxy's page for a host it does not serve", "a body over 16 KB")
  end

  it "asks from outside every answer of the catalogue but the two only the inside spec reaches, and another host, which the proxy answers" do
    reachable = EdgeCheck::CATALOGUE.keys - EdgeCheck::INSIDE_ONLY - [ "another host" ]

    expect(EdgeCheck.asked(host) + [ "a request past the edge's limit" ]).to match_array(reachable)
  end

  it "fails an answer of the application without a header of the set, or with another policy, or with X-Runtime" do
    overrides["an unknown path"] = ->(_) { EdgeCheck::Answer.new(status: 404, headers: set.except("x-frame-options"), body: "") }
    overrides["a static file"] = ->(_) { EdgeCheck::Answer.new(status: 200, headers: set.merge("content-security-policy" => "default-src *"), body: "") }
    overrides["the landing"] = ->(_) { EdgeCheck::Answer.new(status: 200, headers: set.merge("x-runtime" => "0.01"), body: "") }

    expect(run).to be false
    expect(out.string).to include("FAIL an unknown path: no x-frame-options", "FAIL a static file: a policy other than /up's",
                                  "FAIL the landing: x-runtime says too much", "edge-check: 3 failed")
  end

  it "fails the trace's page when it passes a referrer on" do
    overrides["a trace's page"] = ->(_) { EdgeCheck::Answer.new(status: 200, headers: set, body: "") }

    expect(run).to be false
    expect(out.string).to include("FAIL a trace's page: referrer-policy not no-referrer")
  end

  it "fails an answer over HTTPS without HSTS, and a status other than the catalogue's" do
    overrides["a body over 16 KB"] = ->(_) { EdgeCheck::Answer.new(status: 400, headers: set, body: "") }
    overrides["the chat's page"] = ->(_) { EdgeCheck::Answer.new(status: 200, headers: set.except("strict-transport-security"), body: "") }

    expect(run).to be false
    expect(out.string).to include("FAIL a body over 16 KB: status 400, not 413", "FAIL the chat's page: no strict-transport-security")
  end

  it "fails the proxy's redirect to another place and its page when it gives the request back" do
    overrides["the proxy's redirect to HTTPS"] = ->(_) { EdgeCheck::Answer.new(status: 301, headers: { "location" => "https://#{host}/" }, body: "") }
    overrides["the proxy's page for a host it does not serve"] =
      ->(probe) { EdgeCheck::Answer.new(status: 404, headers: {}, body: "no page at #{probe.path}") }

    expect(run).to be false
    expect(out.string).to include("FAIL the proxy's redirect to HTTPS: location", "FAIL the proxy's page for a host it does not serve: the page gives back")
  end

  it "fails when the edge never refuses a request past its limit" do
    overrides["a request past the edge's limit"] = ->(_) { EdgeCheck::Answer.new(status: 401, headers: set, body: "") }

    expect(run).to be false
    expect(out.string).to include("FAIL a request past the edge's limit: no 429 in 70 requests")
  end

  # Review finding C9 of pull request #67: a part of the origin the check
  # would drop (a port, a user, a query) is refused, and so is an origin URI
  # cannot read, which bin/edge-check answers with its usage line.
  it "takes only a host's https origin, refusing what it would drop and what it cannot read" do
    [ "http://#{host}", "https://#{host}/chat", "https://#{host}:8443", "https://user@#{host}", "https://#{host}?q=1",
      "https://#{host}#top", "https:", "https://exa mple" ].each do |origin|
      expect { EdgeCheck::Check.new(origin) }.to raise_error(ArgumentError), origin
    end
  end
end
