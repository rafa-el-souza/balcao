# Sends the web app's HTML shell of a page (design §6.7), rendered at build
# time in the visitor's language (NFR-09, NFR-10; web/vite.config.ts): the
# language chosen on the page's switcher, kept in the `lang` cookie, else the
# first of the three that Accept-Language names, else Portuguese. Only the
# three locales and the route's own page ever name a file. The hashed assets
# a shell names are static files under public/assets, cached for a year; the
# shell itself is revalidated on every visit, or a visitor would keep the
# previous deploy's page. Development serves the shells from the Vite dev
# server instead.
class SpaController < ApplicationController
  include ActionController::Cookies

  LOCALES = I18n.available_locales.map(&:to_s).freeze

  def landing = send_shell("landing")

  def chat = send_shell("chat")

  # The shell is the same for every trace: the token follows the "#" of the
  # link, which no browser sends, and the page reads it and looks the trace up
  # (FR-12; review finding V3 of pull request #17). The link is a credential
  # (threat model SR-11), so the page stays out of search indexes and passes
  # no referrer on.
  def trace
    response.headers["X-Robots-Tag"] = "noindex, nofollow"
    response.headers["Referrer-Policy"] = "no-referrer"
    send_shell("trace")
  end

  # Rails reads the query for its log line before the action runs, and a query
  # it cannot parse (a value not in UTF-8, a key both a string and a hash,
  # nesting too deep) raised BadRequest outside any rescue, an empty 400
  # (review findings C1 and V1 of pull request #14). These pages read no
  # parameter: the page reads its own query, and an unknown say= sends
  # nothing (FR-21, SR-34). So the query the server could not read is dropped
  # and the page is sent.
  def process_action(*)
    super
  rescue ActionController::BadRequest
    raise if request.query_string.empty?

    request.set_header("QUERY_STRING", "")
    request.delete_header("action_dispatch.request.query_parameters")
    super
  end

  private

  def send_shell(page)
    locale = shell_locale
    response.headers["Cache-Control"] = "no-cache"
    response.headers["Vary"] = "Accept-Language, Cookie"
    response.headers["Content-Language"] = locale
    send_file Rails.configuration.x.spa_shells.join("#{page}.#{locale}.html"),
              type: "text/html; charset=utf-8", disposition: "inline"
  end

  def shell_locale
    chosen = cookies[:lang]
    return chosen if LOCALES.include?(chosen)

    RequestLanguage.of(request.headers["Accept-Language"]).to_s
  end
end
