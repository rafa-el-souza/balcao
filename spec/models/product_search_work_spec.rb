require "rails_helper"

# The catalogue search (FR-06, ADR-0009) reads each listed product a fixed
# number of times per query, so its work grows with the catalogue, not with
# its square. The search it replaced read every pair of stems again for each
# product: on 2026-11-14 it took up to 1.1 s at 300 products and up to 11 s
# at 1,000, past the connection's five-second statement timeout (SR-20), so a
# catalogue of a few thousand products failed every search (design §10, the
# note of the catalogue search slice). This counts the rows the plan reads,
# from EXPLAIN ANALYZE, which follows the query's shape and not the speed of
# the machine that runs it. The example holds the planner to nested loops,
# to the join tree as the SQL writes it, and to no node that keeps an inner
# side's rows for the next loop, three things it otherwise picks by its
# estimates, which run low on a catalogue just loaded; a search linear only
# through a hash join reads the square again there. Which side of each join
# is outer stays the planner's choice, so a search square on one side only
# passes on a day the estimates put the other side outer: of this slice's
# two rewrites, the count fails the one linear only through a hash join on
# any day, and failed the one square only with the products outer in the
# slice's runs. Nor does the count see work inside an expression (review
# findings C2 and C3 of pull request #31, written for the owner). It
# measures 100 against 800 products, eight times as many, under a sixteenfold
# bound, which a square term crosses even when it is small beside the rest,
# and on the search's three paths, each checked to be the one its query
# takes: exact ("dipirona"), close ("dipriona", two letters swapped) and
# partial ("dipirona infantil", a word the catalogue lacks; "dipirona gotas"
# scores 0.6 against this catalogue, the bound, and takes the close path);
# the slice measured 50 against 200 and "dipirona" alone (C1 and V1, the MVP
# review).
RSpec.describe "FR-06 ADR-0009 the catalogue search's work grows with the catalogue, not with its square" do
  before do
    %w[enable_hashjoin enable_mergejoin enable_material enable_memoize].each do |setting|
      ApplicationRecord.connection.execute("SET LOCAL #{setting} = off")
    end
    %w[join_collapse_limit from_collapse_limit].each { |setting| ApplicationRecord.connection.execute("SET LOCAL #{setting} = 1") }
  end

  def stock(size)
    ingredients = %w[dipirona paracetamol ibuprofeno loratadina omeprazol amoxicilina losartana metformina sinvastatina cetirizina]
    Product.delete_all
    Product.insert_all(Array.new(size) do |index|
      ingredient = ingredients[index % ingredients.size]
      { sku: "produto-#{index}", name: "#{ingredient.capitalize} #{(index % 9 + 1) * 50} mg, #{(index % 4 + 1) * 10} comprimidos",
        active_ingredient: ingredient, price: 9.9, stock: 10, prescription_required: false }
    end)
  end

  # The rows each node of the plan read, kept or filtered out, times its
  # loops, with the nodes below it (CTEs and subplans among them).
  def rows_read(node)
    rows = node["Actual Rows"] + node.fetch("Rows Removed by Filter", 0) + node.fetch("Rows Removed by Join Filter", 0)
    rows * node["Actual Loops"] + node.fetch("Plans", []).sum { |child| rows_read(child) }
  end

  # The rows Product.search reads for the query, from the plan of the very
  # statement it runs, with the very parameters it sends.
  def work(query)
    sql = binds = nil
    capture = ->(*, payload) { sql, binds = payload.values_at(:sql, :binds) if payload[:name] == "Product Load" }
    ActiveSupport::Notifications.subscribed(capture, "sql.active_record") { Product.search(query) }
    plan = ApplicationRecord.connection.select_value("EXPLAIN (ANALYZE, FORMAT JSON) #{sql}", "EXPLAIN", binds)
    rows_read((plan.is_a?(String) ? JSON.parse(plan) : plan).first.fetch("Plan"))
  end

  PATHS = { "dipirona" => "exact", "dipriona" => "close", "dipirona infantil" => "partial" }.freeze

  it "reads about eight times the rows for eight times the products on each path, where a search product by product reads sixty-four" do
    stock(100)
    expect(PATHS.to_h { |query, _| [ query, Product.search(query).map(&:match).uniq ] }).to eq(PATHS.transform_values { |path| [ path ] })
    small = PATHS.keys.to_h { |query| [ query, work(query) ] }
    stock(800)

    PATHS.each_key { |query| expect(work(query)).to be < 16 * small[query], "#{query}: #{work(query)} rows against #{small[query]}" }
  end
end
