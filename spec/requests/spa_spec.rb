require "rails_helper"

# The web app's hashed assets are static files cached for a year; its HTML
# shells name the current hashes, so each is revalidated on every visit, or a
# visitor would keep the previous deploy's page (design §6.7).
RSpec.describe "Design §6.7 the web app's shell is sent fresh on every visit", :spa_shells, type: :request do
  it "serves the landing at / as UTF-8 HTML that the browser must revalidate" do
    get "/"

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq "text/html"
    expect(response.charset).to eq "utf-8"
    expect(response.headers["Cache-Control"]).to eq "no-cache"
    expect(response.body).to include(%(data-page="landing"))
  end

  it "serves the chat at /chat, whatever the query, and with a trailing slash" do
    get "/chat?say=stock_pt"
    expect(response.body).to include(%(data-page="chat"))

    get "/chat/"
    expect(response.body).to include(%(data-page="chat"))
  end

  # Review findings C1 and V1 of pull request #14: Rails reads the query for
  # its log line before any action runs, and a query it cannot parse answered
  # an empty 400. The page reads its own query (an unknown say= sends nothing,
  # FR-21, SR-34), so the server sends the shell whatever the query.
  it "sends the page for a query Rails cannot parse" do
    { "/chat" => "chat", "/" => "landing" }.each do |path, page|
      [ "?say=%FF", "?say=promo%E7%E3o", "?say=x&say%5Ba%5D=1", "?a#{"%5Ba%5D" * 100}=1" ].each do |query|
        get "#{path}#{query}"

        expect(response).to have_http_status(:ok), "#{path}#{query}"
        expect(response.body).to include(%(data-page="#{page}"))
      end
    end
  end

  # A trace link is a credential (threat model SR-11): the page that opens it
  # stays out of search indexes and sends no referrer on, and its shell is
  # the same whatever the token, which the page reads and looks up itself.
  it "serves the trace page at /trace/:token, for any token, out of indexes and without a referrer (FR-12)" do
    [ "Xy7GqR2mN8pLw4Kd9sTzVb3H", "anything", "%FF", "a%00b" ].each do |token|
      get "/trace/#{token}"

      expect(response).to have_http_status(:ok), token
      expect(response.body).to include(%(data-page="trace"))
      expect(response.headers["Cache-Control"]).to eq "no-cache"
      expect(response.headers["X-Robots-Tag"]).to eq "noindex, nofollow"
      expect(response.headers["Referrer-Policy"]).to eq "no-referrer"
    end
  end

  it "has no shell for a path that is not a page" do
    get "/chats"

    expect(response).to have_http_status(:not_found)
  end
end

# NFR-09: the page is in the visitor's language before any script runs (and
# without one, NFR-10): the language the visitor chose on the switcher, kept
# in a cookie, else the browser's first of the three, else Portuguese.
RSpec.describe "NFR-09 the web app's shell in the visitor's language", :spa_shells, type: :request do
  def lang_of_page = response.body[/<html lang="([^"]+)"/, 1]

  it "follows Accept-Language, the first of the three it names" do
    get "/", headers: { "Accept-Language" => "de-DE, es-UY;q=0.8, en;q=0.5" }

    expect(lang_of_page).to eq "es"
    expect(response.headers["Content-Language"]).to eq "es"
  end

  it "prefers the switcher's choice to the browser's" do
    cookies["lang"] = "en"
    get "/chat", headers: { "Accept-Language" => "es" }

    expect(lang_of_page).to eq "en"
    expect(response.body).to include(%(data-page="chat"))
  end

  it "ignores a cookie that names none of the three, or something else entirely" do
    [ "fr", "../../../config/master", "en%00" ].each do |value|
      cookies["lang"] = value
      get "/", headers: { "Accept-Language" => "es" }

      expect(lang_of_page).to eq "es"
    end
  end

  it "speaks Portuguese to a browser that names none of the three" do
    get "/", headers: { "Accept-Language" => "fr-FR, de" }

    expect(lang_of_page).to eq "pt-BR"
  end

  it "tells caches that the answer depends on the language and the cookie" do
    get "/"

    expect(response.headers["Vary"]).to include("Accept-Language", "Cookie")
  end
end

RSpec.describe "Design §6.7 the web app's shells location" do
  it "is the build output of the web app, where the image puts it too" do
    expect(Rails.application.config.x.spa_shells).to eq Rails.root.join("web/dist/shells")
    expect(Rails.root.join("Dockerfile").read)
      .to include("COPY --chown=rails:rails --from=web /web/dist/shells /rails/web/dist/shells")
  end
end

# Each page the build renders (web/src/pages.ts) in each language
# (web/src/locale.ts) is a shell the server can send, and each route the server
# sends a shell for is one of them: a route without its shell would answer 500
# behind a green deploy (review finding C2 of pull request #14).
RSpec.describe "Design §6.7 the build's pages and the server's routes agree" do
  let(:pages) do
    source = Rails.root.join("web/src/pages.ts").read[/export const PAGES = \{(.*?)\} as const;/m, 1]
    source.scan(/^\s*(\w+): "([^"]+)",?$/).to_h
  end

  it "routes each page's path, with any token, to the action of its name" do
    expect(pages.keys).to include("landing", "chat", "trace")
    pages.each do |page, path|
      recognized = Rails.application.routes.recognize_path(path.gsub(/:\w+/, "Xy7GqR2mN8pLw4Kd9sTzVb3H"))
      expect(recognized).to include(controller: "spa", action: page), path
    end
  end

  it "sends shells only for the build's pages, and the spec fixture writes the same ones" do
    routed = Rails.application.routes.routes.filter_map { |route| route.defaults[:action] if route.defaults[:controller] == "spa" }
    expect(routed.uniq).to match_array(pages.keys)
    expect(SpaShells::PAGES).to match_array(pages.keys)
  end

  it "renders the languages the server chooses among" do
    locales = Rails.root.join("web/src/locale.ts").read[/export const LOCALES = \[(.*?)\] as const;/, 1].scan(/"([^"]+)"/).flatten
    expect(locales).to eq(I18n.available_locales.map(&:to_s))
    expect(SpaShells::LOCALES).to eq(locales)
  end
end
