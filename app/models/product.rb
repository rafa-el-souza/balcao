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

  # The SQL of Product.search, below, which says what each part does.
  SEARCH = <<~SQL.squish.freeze
    WITH texts AS (
      SELECT NULL::uuid AS id, 'query' AS kind, unaccent(lower(:query)) AS text
      UNION ALL
      SELECT products.id, part.kind, part.text
      FROM products
      CROSS JOIN LATERAL (VALUES
        ('whole', unaccent(lower(products.name || ' ' || coalesce(products.active_ingredient, '')))),
        ('ingredient', unaccent(lower(coalesce(products.active_ingredient, '')))),
        ('head', regexp_replace(unaccent(lower(products.name)), '[0-9,:].*$', ''))
      ) AS part (kind, text)
      WHERE products.listed
    ),
    stemmed AS (
      SELECT id, kind, text,
             ARRAY(SELECT DISTINCT stem FROM unnest(
               tsvector_to_array(to_tsvector('portuguese', text)) ||
               ARRAY(SELECT word FROM unnest(tsvector_to_array(to_tsvector('simple', text))) AS word WHERE length(word) = 1)
             ) AS stem) AS stems
      FROM texts
    ),
    query AS (
      SELECT text, stems FROM stemmed WHERE kind = 'query'
    ),
    pairs AS (
      SELECT whole.id, asked, found,
             asked = found OR (length(asked) >= 5 AND (
               levenshtein_less_equal(asked, found, 1) <= 1 OR
               (length(asked) = length(found) AND levenshtein_less_equal(asked, found, 2) <= 2 AND
                (SELECT string_agg(letter, '' ORDER BY letter) FROM regexp_split_to_table(asked, '') AS letter) =
                (SELECT string_agg(letter, '' ORDER BY letter) FROM regexp_split_to_table(found, '') AS letter))
             )) AS alike
      FROM stemmed AS whole
      CROSS JOIN query
      CROSS JOIN unnest(query.stems) AS asked
      CROSS JOIN unnest(whole.stems) AS found
      WHERE whole.kind = 'whole'
    ),
    candidates AS (
      SELECT products.*,
             word_similarity(query.text, whole.text) AS similarity,
             cardinality(query.stems) AS wanted,
             (SELECT count(DISTINCT asked) FROM pairs WHERE pairs.id = products.id AND asked = found) AS held,
             (SELECT count(DISTINCT asked) FROM pairs WHERE pairs.id = products.id AND alike) AS near,
             EXISTS (
               SELECT 1 FROM stemmed AS part
               WHERE part.id = products.id AND part.kind IN ('ingredient', 'head') AND cardinality(part.stems) > 0
                 AND NOT EXISTS (
                   SELECT 1 FROM unnest(part.stems) AS stem
                   WHERE NOT EXISTS (SELECT 1 FROM pairs WHERE pairs.id = products.id AND found = stem AND asked = found)
                 )
             ) AS named
      FROM products
      JOIN stemmed AS whole ON whole.id = products.id AND whole.kind = 'whole'
      CROSS JOIN query
    ),
    matched AS (
      SELECT candidates.*,
             CASE WHEN wanted > 0 AND held = wanted THEN 'exact'
                  WHEN similarity >= :similarity OR (wanted > 0 AND near = wanted) THEN 'close'
                  WHEN named THEN 'partial'
             END AS match
      FROM candidates
    )
    SELECT matched.*, round(similarity::numeric, 2)::float AS score
    FROM matched
    WHERE match IS NOT NULL
      AND (match <> 'partial' OR NOT EXISTS (SELECT 1 FROM matched AS better WHERE better.match <> 'partial'))
    ORDER BY array_position(ARRAY['exact', 'close', 'partial'], match), near DESC, score DESC, name
    LIMIT :limit
  SQL
  private_constant :SEARCH

  # The catalogue search of search_products (FR-06, ADR-0009), over the
  # products the catalogue file lists (FR-26). The query and the product's
  # name and active ingredient are folded (lower case, no accents) and split
  # into stems: Portuguese stems, stop words left out, plus the one-letter
  # words the stop words would take with them ("vitamina e" is not
  # "vitamina"; review finding R2 of pull request #10). A product matches
  #
  # - exact when it holds every stem of the query, in any order;
  # - close when its trigrams are near the query's (pg_trgm's word
  #   similarity from SIMILARITY) or each stem of the query is alike one of
  #   its stems: the same, or from five letters one edit away (Levenshtein
  #   distance) or the same letters with two swapped. That takes a typo, two
  #   swapped letters included ("dipriona"; review finding C3 of pull request
  #   #10), and another product with a similar name, which search_products
  #   tells the model apart; two edits of any kind would reach other
  #   medicines ("ampicilina" is two from amoxicilina; review finding R3);
  # - partial when the query names it, that is holds every stem of its
  #   active ingredient or of the head of its name (the words before the
  #   first number or comma), and adds words the catalogue lacks; offered
  #   only when no product matches exact or close. So "paracetamol infantil"
  #   still finds the paracetamol the store carries (review finding C1 of
  #   pull request #10), "dipirona gotas" lists no other drops, and a
  #   medicine not carried that shares only a word with one carried ("ácido
  #   acetilsalicílico" and "ácido ascórbico", a salt, a unit) finds nothing,
  #   which the model reports as not carried (review finding R1).
  #
  # Ranked by match, then by the stems alike the query's, then by the trigram
  # score (rounded to two places, carried by each product), then by name.
  # The SQL is plain text, with the query bound: no fragment is interpolated
  # (threat model SR-28).
  #
  # No index: the catalogue is a few hundred rows at most (ADR-0009), which
  # the planner reads whole anyway. A catalogue of thousands would want an
  # immutable unaccent wrapper and a trigram index on it, which schema.rb
  # cannot hold, so that is ADR-0009's revisit, not this method's.
  def self.search(query, limit: 5) = find_by_sql([ SEARCH, { query:, similarity: SIMILARITY, limit: } ])
end
