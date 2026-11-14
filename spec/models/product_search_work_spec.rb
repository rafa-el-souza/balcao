require "rails_helper"

# The catalogue search (FR-06, ADR-0009) reads each listed product a fixed
# number of times per query, so its work grows with the catalogue, not with
# its square. The search it replaced read every pair of stems again for each
# product: on 2026-11-14 it took up to 1.1 s at 300 products and up to 11 s
# at 1,000, past the connection's five-second statement timeout (SR-20), so a
# catalogue of a few thousand products failed every search (design §10, the
# note of the catalogue search slice). This counts the rows the plan reads,
# from EXPLAIN ANALYZE, which follows the query's shape and not the speed of
# the machine that runs it. The example takes the plan a search may meet at
# its worst: nested loops only, in the order the SQL writes its joins, with
# no node that keeps an inner side's rows for the next loop. The planner
# chooses all three by its estimates, which run low on a catalogue just
# loaded, and a search that is linear only through a hash join, or only when
# the planner keeps the one-row query aside, reads the square again there (a
# rewrite of this slice did, at 10,000 products, and passed at 200).
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
  # statement it runs.
  def work(query)
    sql = nil
    capture = ->(*, payload) { sql = payload[:sql] if payload[:name] == "Product Load" }
    ActiveSupport::Notifications.subscribed(capture, "sql.active_record") { Product.search(query) }
    plan = ApplicationRecord.connection.select_value("EXPLAIN (ANALYZE, FORMAT JSON) #{sql}")
    rows_read((plan.is_a?(String) ? JSON.parse(plan) : plan).first.fetch("Plan"))
  end

  it "reads about four times the rows for four times the products, where a search product by product reads sixteen" do
    stock(50)
    small = work("dipirona")
    stock(200)

    expect(work("dipirona")).to be < 8 * small
  end
end
