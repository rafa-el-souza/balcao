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

  # The salts an active ingredient carries beside the medicine, which no one
  # says when asking for it ("losartana", not "losartana potássica"), folded
  # as the search folds a text, as whole words: "potássica" is a salt,
  # "potássio" the medicine of "cloreto de potássio". Set aside only where a
  # dose query names a product's medicine (review findings V1 and R1 of
  # pull request #40). A short list, for the seed: a real catalogue's salts
  # come with the data-contract ADR.
  SALTS = %w[
    potassica potassico sodica sodico calcica calcico cloridrato bromidrato maleato besilato mesilato
    succinato fumarato hemifumarato tartarato
  ].freeze
  # The pattern the SQL sets the salts aside with: Postgres's word boundaries.
  SALT_WORDS = "\\m(#{SALTS.join("|")})\\M".freeze

  # The parts of a name the search and named_in both read, written once: the
  # head of a name, the words before its first number or comma; the active
  # ingredient with its salt set aside, BARE, then the salts' pattern, which
  # each statement passes as a parameter of its own, then BARE_END; the stems
  # of a folded text; and when a stem the text asks for is alike one a product
  # holds. Search below says what each one does. They are literals, joined
  # into the statements as they load: no value of a request is ever in them.
  HEAD = "regexp_replace(unaccent(lower(products.name)), '[0-9,:].*$', '')".freeze
  BARE = "regexp_replace(unaccent(lower(coalesce(products.active_ingredient, ''))),".freeze
  BARE_END = ", '', 'g')".freeze
  STEMS = <<~SQL.squish.freeze
    ARRAY(SELECT DISTINCT stem FROM unnest(
      tsvector_to_array(to_tsvector('portuguese', text)) ||
      ARRAY(SELECT word FROM unnest(tsvector_to_array(to_tsvector('simple', text))) AS word WHERE length(word) = 1)
    ) AS stem)
  SQL
  ALIKE = <<~SQL.squish.freeze
    asked = found OR (length(asked) >= 5 AND (
      levenshtein_less_equal(asked, found, 1) <= 1 OR
      (length(asked) = length(found) AND levenshtein_less_equal(asked, found, 2) <= 2 AND
       (SELECT string_agg(letter, '' ORDER BY letter) FROM regexp_split_to_table(asked, '') AS letter) =
       (SELECT string_agg(letter, '' ORDER BY letter) FROM regexp_split_to_table(found, '') AS letter))
    ))
  SQL

  # The SQL of Product.search, below, which says what each part does.
  SEARCH = <<~SQL.squish.freeze
    WITH texts AS (
      SELECT NULL::uuid AS id, NULL AS name, 'query' AS kind, unaccent(lower($1)) AS text
      UNION ALL
      SELECT products.id, products.name, part.kind, part.text
      FROM products
      CROSS JOIN LATERAL (VALUES
        ('whole', unaccent(lower(products.name || ' ' || coalesce(products.active_ingredient, '')))),
        ('ingredient', unaccent(lower(coalesce(products.active_ingredient, '')))),
        ('head', #{HEAD}),
        ('bare', #{BARE} $4#{BARE_END})
      ) AS part (kind, text)
      WHERE products.listed
    ),
    stemmed AS (
      SELECT id, name, kind, text, #{STEMS} AS stems
      FROM texts
    ),
    query AS MATERIALIZED (
      SELECT text, stems,
             ARRAY(SELECT stem FROM unnest(stems) AS stem
                   WHERE stem !~ '^[0-9]' AND stem <> ALL (ARRAY['mg', 'g', 'mcg', 'ml', 'l', 'ui'])) AS words
      FROM stemmed WHERE kind = 'query'
    ),
    folded AS (
      SELECT id, max(name) AS name,
             max(text) FILTER (WHERE kind = 'whole') AS text,
             max(stems) FILTER (WHERE kind = 'whole') AS stems,
             max(stems) FILTER (WHERE kind = 'ingredient') AS ingredient,
             max(stems) FILTER (WHERE kind = 'head') AS head,
             max(stems) FILTER (WHERE kind = 'bare') AS bare
      FROM stemmed
      WHERE kind <> 'query'
      GROUP BY id
    ),
    candidates AS (
      SELECT folded.id, folded.name,
             word_similarity(query.text, folded.text) AS similarity,
             cardinality(query.stems) AS wanted,
             cardinality(query.words) AS words,
             tally.held, tally.near, tally.near_words,
             coalesce(cardinality(folded.ingredient) > 0 AND folded.ingredient <@ tally.alike, false)
               OR coalesce(cardinality(folded.head) > 0 AND folded.head <@ tally.alike, false) AS named,
             coalesce(cardinality(folded.bare) > 0 AND folded.bare <@ tally.alike, false) AS named_bare
      FROM folded
      CROSS JOIN query
      CROSS JOIN LATERAL (
        SELECT count(DISTINCT asked) FILTER (WHERE asked = found) AS held,
               count(DISTINCT asked) FILTER (WHERE alike) AS near,
               count(DISTINCT asked) FILTER (WHERE alike AND asked = ANY (query.words)) AS near_words,
               coalesce(array_agg(DISTINCT found) FILTER (WHERE alike), ARRAY[]::text[]) AS alike
        FROM (
          SELECT asked, found, #{ALIKE} AS alike
          FROM unnest(query.stems) AS asked
          CROSS JOIN unnest(folded.stems) AS found
        ) AS pair
      ) AS tally
    ),
    matched AS (
      SELECT candidates.*,
             CASE WHEN wanted > 0 AND held = wanted THEN 'exact'
                  WHEN similarity >= $2 OR (wanted > 0 AND near = wanted) THEN 'close'
                  WHEN named OR (words > 0 AND words < wanted AND near_words = words AND named_bare) THEN 'partial'
             END AS match
      FROM candidates
    ),
    ranked AS (
      SELECT matched.*, round(similarity::numeric, 2)::float AS score
      FROM matched
      WHERE match IS NOT NULL
        AND (match <> 'partial' OR NOT EXISTS (SELECT 1 FROM matched AS better WHERE better.match <> 'partial'))
      ORDER BY array_position(ARRAY['exact', 'close', 'partial'], match), near DESC, score DESC, name
      LIMIT $3
    )
    SELECT products.*, ranked.similarity, ranked.wanted, ranked.held, ranked.near, ranked.named, ranked.match, ranked.score
    FROM ranked
    JOIN products ON products.id = ranked.id
    ORDER BY array_position(ARRAY['exact', 'close', 'partial'], ranked.match), ranked.near DESC, ranked.score DESC, ranked.name
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
  # - partial when the query names it, that is holds a stem alike each stem
  #   of its active ingredient or of the head of its name (the words before
  #   the first number or comma), a typo included (review finding R4 of pull
  #   request #10), and adds words the catalogue lacks; or when the query
  #   has a dose (a number, alone or joined to its unit, and the units mg,
  #   g, mcg, ml, l and ui), names the product's active ingredient with its
  #   salt set aside (SALTS), and its other words are each alike one of the
  #   product's, so "losartana 100 mg" finds the "Losartana potássica 50 mg"
  #   the store carries, though no one says "potássica", and "potássio 600
  #   mg" does not (#14's line; the owner's exception to the data-contract
  #   gate, 2026-11-15, the dose queries alone: review findings V1 and R1 of
  #   pull request #40); offered
  #   only when no product matches exact or close. So "paracetamol infantil"
  #   still finds the paracetamol the store carries (review finding C1 of
  #   pull request #10), "dipirona gotas" lists no other drops, and a
  #   medicine not carried that shares only a word with one carried ("ácido
  #   acetilsalicílico" and "ácido ascórbico", a salt, a unit) finds nothing,
  #   which the model reports as not carried (review finding R1).
  #
  # Ranked by match, then by the stems alike the query's, then by the trigram
  # score (rounded to two places, carried by each product), then by name.
  # The SQL is plain text and the query a parameter of the statement, never
  # quoted into its text: no fragment is interpolated (threat model SR-28),
  # and the database's own log, which keeps a statement's text when it ends
  # in an error, never holds the visitor's words (SR-30; review findings C1
  # and V2 of pull request #40).
  #
  # The work grows with the catalogue, whatever plan the planner picks: each
  # product becomes one row holding its stems (folded), and its pairs with the
  # query's stems are counted from that row alone (tally), so no step looks a
  # product up in a set the size of the catalogue. The query's one row is
  # computed once (MATERIALIZED), or a nested loop reads all the stems again
  # for each product to find it. Only the products ranked join the table
  # again, by key. Counting the pairs among every product's, once per product,
  # made the work grow with the square of the catalogue: up to 1.1 s at 300
  # products and 11 s at 1,000, past the statement timeout (SR-20; design §10,
  # the note of the catalogue search slice; spec/models/
  # product_search_work_spec.rb).
  #
  # No index: every call folds and stems every listed product, about half of
  # the 0.7 to 1 s a search takes at 10,000 products (design §10). A
  # catalogue of thousands would want the folded texts and stems computed
  # when the catalogue is loaded, with a trigram index on them: ADR-0009's
  # revisit, not this method's.
  def self.search(query, limit: 5) = find_by_sql(SEARCH, [ query, SIMILARITY, limit, SALT_WORDS ])

  # The SQL of Product.named_in, below.
  NAMED = <<~SQL.squish.freeze
    WITH texts AS (
      SELECT NULL::uuid AS id, 'message' AS kind, unaccent(lower($1)) AS text
      UNION ALL
      SELECT products.id, part.kind, part.text
      FROM products
      CROSS JOIN LATERAL (VALUES ('head', #{HEAD}), ('bare', #{BARE} $3#{BARE_END})) AS part (kind, text)
      WHERE products.id = ANY (string_to_array($2, ',')::uuid[]) AND products.listed
    ),
    stemmed AS (
      SELECT id, kind, #{STEMS} AS stems FROM texts
    ),
    message AS MATERIALIZED (
      SELECT ARRAY(SELECT stem FROM unnest(stems) AS stem WHERE length(stem) <= 64) AS stems FROM stemmed WHERE kind = 'message'
    )
    SELECT products.*
    FROM products
    WHERE products.id IN (
      SELECT stemmed.id
      FROM stemmed CROSS JOIN message
      WHERE stemmed.kind <> 'message' AND cardinality(stemmed.stems) > 0
        AND NOT EXISTS (
          SELECT 1 FROM unnest(stemmed.stems) AS found
          WHERE NOT EXISTS (SELECT 1 FROM unnest(message.stems) AS asked WHERE #{ALIKE})
        )
    )
    ORDER BY products.name
  SQL
  private_constant :NAMED

  # FR-20 (#59's C2 and H2, the owner, 2026-11-20): the products among ids
  # that the catalogue still lists and a visitor's message names, as the
  # search reads a name: every stem of the product's active ingredient, its
  # salt set aside, or of the head of its name, alike a stem of the message, a
  # typo included. So "tem losartana?" names the Losartana potássica though no
  # one says "potássica", "do you have amoxicillin?" names the amoxicilina,
  # and "tem alguma coisa pra azia?" names the omeprazol a search for it found
  # no more than "potássio" names the losartana. A reply the guardrail
  # replaced lists only these, so a product the model chose for a symptom
  # never reaches the visitor as the system's own line
  # (TurnProcessor#products_of). A word of the message over 64 characters
  # names nothing: no product's word is that long, and the likeness asks
  # levenshtein_less_equal, which refuses one over 255, where a visitor's
  # message of up to 1,000 holds a pasted link as one word (review finding
  # H-B1 of pull request #60). A product the catalogue's reload unlisted since
  # an earlier turn's search found it names nothing, as no search finds it
  # (review finding R3 of pull request #60). The message is a parameter of the
  # statement, never quoted into its text (threat model SR-28, SR-30).
  def self.named_in(text, ids)
    return none if ids.empty?

    find_by_sql(NAMED, [ text.to_s, ids.join(","), SALT_WORDS ])
  end
end
