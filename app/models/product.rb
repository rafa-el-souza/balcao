# A catalogue product of the fictional store (FR-06), seeded and reset nightly (FR-15).
class Product < ApplicationRecord
  has_many :reservations

  validates :sku, :name, presence: true
  validates :price, numericality: { greater_than_or_equal_to: 0 }
  validates :stock, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  # The least trigram word similarity for a close match: pg_trgm's own default
  # for word similarity, which keeps a one-letter typo ("dipirna",
  # "omeprasol") and drops a shared suffix ("comprimidos" alone).
  SIMILARITY = 0.6

  # How well a product matches a query, best first.
  MATCHES = %w[exact close partial].freeze

  # The catalogue search of search_products (FR-06, ADR-0009), over the
  # products the catalogue file lists (FR-26). The query and the product's
  # name and active ingredient are folded (lower case, no accents) and split
  # into Portuguese stems, stop words left out. A product matches
  #
  # - exact when it holds every stem of the query, in any order;
  # - close when its trigrams are near the query's (pg_trgm's word
  #   similarity from SIMILARITY): a typo, or another product with a similar
  #   name, which search_products tells the model apart;
  # - partial when it holds some stems of the query, offered only when no
  #   product matches exact or close, so "paracetamol infantil" still finds
  #   the paracetamol the store carries (review finding C1 of pull request
  #   #10) and "dipirona gotas" lists no other drops.
  #
  # Ranked by match, then by the stems it holds, then by the trigram score
  # (rounded to two places, carried by each product), then by name.
  #
  # No index: the catalogue is a few hundred rows at most (ADR-0009), which
  # the planner reads whole anyway. A catalogue of thousands would want an
  # immutable unaccent wrapper and a trigram index on it, which schema.rb
  # cannot hold, so that is ADR-0009's revisit, not this method's.
  def self.search(query, limit: 5)
    find_by_sql([ <<~SQL.squish, { query:, similarity: SIMILARITY, limit: } ])
      WITH query AS (
        SELECT unaccent(lower(:query)) AS text,
               tsvector_to_array(to_tsvector('portuguese', unaccent(lower(:query)))) AS stems
      ),
      candidates AS (
        SELECT products.*,
               word_similarity(query.text, folded.text) AS similarity,
               cardinality(query.stems) AS wanted,
               (SELECT count(*) FROM unnest(query.stems) AS stem WHERE stem = ANY (folded.stems)) AS held
        FROM products
        CROSS JOIN query
        CROSS JOIN LATERAL (
          SELECT text, tsvector_to_array(to_tsvector('portuguese', text)) AS stems
          FROM (SELECT unaccent(lower(products.name || ' ' || coalesce(products.active_ingredient, ''))) AS text) AS product
        ) AS folded
        WHERE products.listed
      ),
      matched AS (
        SELECT candidates.*,
               CASE WHEN wanted > 0 AND held = wanted THEN 'exact'
                    WHEN similarity >= :similarity THEN 'close'
                    WHEN held > 0 THEN 'partial'
               END AS match
        FROM candidates
      )
      SELECT matched.*, round(similarity::numeric, 2)::float AS score
      FROM matched
      WHERE match IS NOT NULL
        AND (match <> 'partial' OR NOT EXISTS (SELECT 1 FROM matched AS better WHERE better.match <> 'partial'))
      ORDER BY array_position(ARRAY['exact', 'close', 'partial'], match), held DESC, score DESC, name
      LIMIT :limit
    SQL
  end
end
