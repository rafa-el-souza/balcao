require "rails_helper"
require "tmpdir"

# The web app's hashed assets are static files cached for a year; its HTML
# shell names the current hashes, so it is revalidated on every visit, or a
# visitor of the placeholder would keep it after the next deploy (design §6.7).
RSpec.describe "Design §6.7 the web app's shell is sent fresh on every visit", type: :request do
  around do |example|
    Dir.mktmpdir("spa") do |dir|
      shell = Pathname(dir).join("index.html")
      shell.write(%(<!doctype html><html lang="pt-BR"><body><div id="root"></div></body></html>))
      original = Rails.configuration.x.spa_shell
      Rails.configuration.x.spa_shell = shell
      example.run
    ensure
      Rails.configuration.x.spa_shell = original
    end
  end

  it "serves the shell at / as UTF-8 HTML that the browser must revalidate" do
    get "/"

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq "text/html"
    expect(response.charset).to eq "utf-8"
    expect(response.headers["Cache-Control"]).to eq "no-cache"
    expect(response.body).to include(%(<div id="root">))
  end
end

RSpec.describe "Design §6.7 the web app's shell location" do
  it "is the build output of the web app, where the image puts it too" do
    expect(Rails.application.config.x.spa_shell).to eq Rails.root.join("web/dist/index.html")
  end
end
