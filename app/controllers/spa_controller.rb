# Sends the web app's HTML shell (design §6.7). The hashed assets it names are
# static files under public/assets, cached for a year; the shell itself is
# revalidated on every visit, or a visitor would keep the previous deploy's
# page. Development serves the shell from the Vite dev server instead.
class SpaController < ApplicationController
  def show
    response.headers["Cache-Control"] = "no-cache"
    send_file Rails.configuration.x.spa_shell, type: "text/html; charset=utf-8", disposition: "inline"
  end
end
