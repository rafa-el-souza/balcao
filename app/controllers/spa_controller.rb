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
