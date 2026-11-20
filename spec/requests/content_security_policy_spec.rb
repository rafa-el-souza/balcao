require "rails_helper"

# Threat model SR-03: a strict policy with no inline script, whose only
# third-party origin is Cloudflare's challenge, for Turnstile's script and its
# frame (SR-39, ADR-0012; Cloudflare's docs, "Content Security Policy", read on
# 2026-11-20).
RSpec.describe "SR-03 SR-39 the Content-Security-Policy of every response", :spa_shells, type: :request do
  challenge = "https://challenges.cloudflare.com"

  def directives
    response.headers["Content-Security-Policy"].split(";").to_h do |directive|
      name, *sources = directive.split
      [ name, sources ]
    end
  end

  it "sends the web app's shell with styles and everything else from its own origin, scripts and frames from Turnstile's too" do
    get "/"

    expect(directives).to include(
      "default-src" => [ "'self'" ], "script-src" => [ "'self'", challenge ], "style-src" => [ "'self'" ],
      "img-src" => [ "'self'", "data:" ], "font-src" => [ "'self'" ], "object-src" => [ "'none'" ],
      "base-uri" => [ "'none'" ], "form-action" => [ "'self'" ], "frame-ancestors" => [ "'none'" ],
      "frame-src" => [ challenge ]
    )
  end

  it "lets the page reach the API and the cable on its own origin, the cable named for browsers that read 'self' as http only" do
    get "/"

    cable = Rails.configuration.x.public_origin.sub(/\Ahttp/, "ws")
    expect(directives["connect-src"]).to eq [ "'self'", cable ]
  end

  it "names no third party but Turnstile's, in scripts and frames alone, and allows no inline or evaluated script anywhere" do
    get "/"

    sources = directives.values.flatten
    expect(sources).not_to include("'unsafe-inline'", "'unsafe-eval'", "*", "https:", "http:")
    expect(sources.grep(%r{//}) - [ challenge ]).to all(start_with(Rails.configuration.x.public_origin.sub(/\Ahttp/, "ws")))
    expect(directives.select { |_, values| values.include?(challenge) }.keys).to contain_exactly("script-src", "frame-src")
  end

  it "sends the same policy with the API's answers" do
    get "/api/conversations/current"

    expect(directives["default-src"]).to eq [ "'self'" ]
    expect(directives["frame-ancestors"]).to eq [ "'none'" ]
  end
end
