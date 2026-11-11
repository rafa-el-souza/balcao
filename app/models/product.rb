# A catalogue product of the fictional store (FR-06), seeded and reset nightly (FR-15).
class Product < ApplicationRecord
  has_many :reservations

  validates :sku, :name, presence: true
  validates :price, numericality: { greater_than_or_equal_to: 0 }
  validates :stock, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  # The least trigram word similarity a product needs to match without the
  # full-text match: pg_trgm's own default for word similarity, which keeps
  # a one-letter typo ("dipirna", "omeprasol") and drops a shared suffix
  # ("comprimidos" alone).
  SIMILARITY = 0.6

  # The catalogue search of search_products (FR-06, ADR-0009). The query is
  # folded like the product's name and active ingredient (lower case, no
  # accents) and a product matches when the query's trigrams are close to a
  # stretch of that text (typos) or when every word of the query, stemmed in
  # Portuguese, is in it (words in any order). Ranked by the trigram score,
  # rounded to two places, then by name; each product carries its score.
  #
  # No index: the catalogue is a few hundred rows at most (ADR-0009), which
  # the planner reads whole anyway. A catalogue of thousands would want an
  # immutable unaccent wrapper and a trigram index on it, which schema.rb
  # cannot hold, so that is ADR-0009's revisit, not this method's.
  def self.search(query, limit: 5)
    folded = "unaccent(lower(:query))"
    text = "unaccent(lower(products.name || ' ' || coalesce(products.active_ingredient, '')))"
    score = "word_similarity(#{folded}, #{text})"
    words = "to_tsvector('portuguese', #{text}) @@ plainto_tsquery('portuguese', #{folded})"

    select("products.*", sanitize_sql_array([ "round(#{score}::numeric, 2)::float AS score", { query: } ]))
      .where(sanitize_sql_array([ "#{score} >= :similarity OR #{words}", { query:, similarity: SIMILARITY } ]))
      .order(Arel.sql("score DESC, products.name"))
      .limit(limit)
  end
end
