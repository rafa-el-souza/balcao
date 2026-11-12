require "rails_helper"

# Threat model SR-03 for the MVP: a strict policy with no inline script and
# no third-party origin (Turnstile's, the only one, arrives with SR-39 after
# the MVP; design FR-18's MVP note).
RSpec.describe "SR-03 the Content-Security-Policy of every response", :spa_shells, type: :request do
  def directives
    response.headers["Content-Security-Policy"].split(";").to_h do |directive|
      name, *sources = directive.split
      [ name, sources ]
    end
  end

  it "sends the web app's shell with scripts, styles and everything else from its own origin only" do
    get "/"

    expect(directives).to include(
      "default-src" => [ "'self'" ], "script-src" => [ "'self'" ], "style-src" => [ "'self'" ],
      "img-src" => [ "'self'", "data:" ], "font-src" => [ "'self'" ], "object-src" => [ "'none'" ],
      "base-uri" => [ "'none'" ], "form-action" => [ "'self'" ], "frame-ancestors" => [ "'none'" ]
    )
  end

  it "lets the page reach the API and the cable on its own origin, the cable named for browsers that read 'self' as http only" do
    get "/"

    cable = Rails.configuration.x.public_origin.sub(/\Ahttp/, "ws")
    expect(directives["connect-src"]).to eq [ "'self'", cable ]
  end

  it "names no third party and allows no inline or evaluated script anywhere" do
    get "/"

    sources = directives.values.flatten
    expect(sources).not_to include("'unsafe-inline'", "'unsafe-eval'", "*", "https:", "http:")
    expect(sources.grep(%r{//})).to all(start_with(Rails.configuration.x.public_origin.sub(/\Ahttp/, "ws")))
  end

  it "sends the same policy with the API's answers" do
    get "/api/conversations/current"

    expect(directives["default-src"]).to eq [ "'self'" ]
    expect(directives["frame-ancestors"]).to eq [ "'none'" ]
  end
end
