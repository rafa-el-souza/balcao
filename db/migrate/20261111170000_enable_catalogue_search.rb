# The catalogue search of search_products (FR-06, ADR-0009): pg_trgm for the
# trigram similarity that tolerates typos, unaccent so "termometro" finds
# "Termômetro". Both ship with PostgreSQL and are trusted extensions, so the
# database's owner creates them.
class EnableCatalogueSearch < ActiveRecord::Migration[8.1]
  def change
    enable_extension "pg_trgm"
    enable_extension "unaccent"
  end
end
