require "tmpdir"

# The web app's page shells, one per page and language (web/vite.config.ts),
# written into a scratch directory for the request specs: each names its page
# and language, so a spec can tell which one the server sent.
module SpaShells
  PAGES = %w[landing chat].freeze
  LOCALES = %w[pt-BR en es].freeze

  def self.around(example)
    Dir.mktmpdir("spa") do |dir|
      PAGES.product(LOCALES).each do |page, locale|
        Pathname(dir).join("#{page}.#{locale}.html").write(
          %(<!doctype html><html lang="#{locale}"><body><div id="root" data-page="#{page}"></div></body></html>)
        )
      end
      original = Rails.configuration.x.spa_shells
      Rails.configuration.x.spa_shells = Pathname(dir)
      example.run
    ensure
      Rails.configuration.x.spa_shells = original
    end
  end
end

RSpec.configure do |config|
  config.around(:example, :spa_shells) { |example| SpaShells.around(example) }
end
