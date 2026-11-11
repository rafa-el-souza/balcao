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

  # The catalogue search of search_products (FR-06, ADR-0009), over the
  # products the catalogue file lists (FR-26). The query and the product's
  # name and active ingredient are folded (lower case, no accents) and split
  # into stems (Product.stems). A product matches
  #
  # - exact when it holds every stem of the query, in any order;
  # - close when its trigrams are near the query's (pg_trgm's word
  #   similarity from SIMILARITY) or each stem of the query is near one of
  #   its stems (Product.near): a typo, two swapped letters included (review
  #   finding C3 of pull request #10), or another product with a similar
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
        SELECT text, #{stems("text")} AS stems FROM (SELECT unaccent(lower(:query)) AS text) AS typed
      ),
      candidates AS (
        SELECT products.*,
               word_similarity(query.text, folded.text) AS similarity,
               cardinality(query.stems) AS wanted,
               (SELECT count(*) FROM unnest(query.stems) AS stem WHERE stem = ANY (folded.stems)) AS held,
               (SELECT count(*) FROM unnest(query.stems) AS stem
                WHERE EXISTS (SELECT 1 FROM unnest(folded.stems) AS other WHERE #{near("stem", "other")})) AS near
        FROM products
        CROSS JOIN query
        CROSS JOIN LATERAL (
          SELECT text, #{stems("text")} AS stems
          FROM (SELECT unaccent(lower(products.name || ' ' || coalesce(products.active_ingredient, ''))) AS text) AS product
        ) AS folded
        WHERE products.listed
      ),
      matched AS (
        SELECT candidates.*,
               CASE WHEN wanted > 0 AND held = wanted THEN 'exact'
                    WHEN similarity >= :similarity OR (wanted > 0 AND near = wanted) THEN 'close'
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

  # The stems of a folded text, as an SQL expression: its Portuguese stems,
  # stop words left out, and its one-letter words, which the stop words would
  # take with them ("vitamina e" is not "vitamina"; review finding R2 of pull
  # request #10).
  def self.stems(text)
    "ARRAY(SELECT DISTINCT stem FROM unnest(tsvector_to_array(to_tsvector('portuguese', #{text})) || " \
      "ARRAY(SELECT word FROM unnest(tsvector_to_array(to_tsvector('simple', #{text}))) AS word WHERE length(word) = 1)) AS stem)"
  end
  private_class_method :stems

  # Whether a stem of the query is near a stem of the product, as an SQL
  # expression: the same; or, from five letters, one edit away (Levenshtein
  # distance), or the same letters with two swapped ("dipriona", "alocol";
  # review finding C3 of pull request #10). Two edits of any kind would reach
  # other medicines ("ampicilina" is two from amoxicilina; review finding R3).
  def self.near(stem, other)
    "(#{stem} = #{other} OR (length(#{stem}) >= 5 AND (levenshtein_less_equal(#{stem}, #{other}, 1) <= 1 OR " \
      "(length(#{stem}) = length(#{other}) AND levenshtein_less_equal(#{stem}, #{other}, 2) <= 2 AND " \
      "#{letters(stem)} = #{letters(other)}))))"
  end
  private_class_method :near

  def self.letters(stem) = "(SELECT string_agg(letter, '' ORDER BY letter) FROM regexp_split_to_table(#{stem}, '') AS letter)"
  private_class_method :letters
end
