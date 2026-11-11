module Tools
  # The catalogue lookup (FR-06, ADR-0009): up to five products for a query,
  # each with its id (for create_reservation, PR-13), its price as the visitor
  # reads it, its stock, its prescription flag and how it matched
  # (Product.search). The model normalises the
  # query first, as the description asks: the catalogue is in Portuguese and
  # names medicines by active ingredient, never by brand (SR-33). The schema
  # cannot bound the limit for the model (the SDK moves such constraints into
  # the description), so the limit and the query are checked here (SR-16).
  # A product's name reaches the model as a JSON string, data like the rest
  # of the result (SR-21).
  class SearchProducts < AgentTool
    MAX_RESULTS = 5
    MAX_QUERY = 100

    class Input < Anthropic::BaseModel
      required :query, String, doc: "A product name or an active ingredient, in Portuguese."
      optional :limit, Integer, doc: "How many products to return, from 1 to #{MAX_RESULTS}; #{MAX_RESULTS} when left out."
    end

    EMPTY = "The query is empty. Search by a product's name or active ingredient.".freeze
    LONG = "The query is longer than #{MAX_QUERY} characters. Search by a product's name or active ingredient.".freeze

    doc "Search the pharmacy's catalogue by product name or active ingredient. Call it whenever the visitor asks " \
        "whether the pharmacy has a product, what it costs, whether it is in stock or whether it requires a " \
        "prescription; never answer these from memory. The catalogue is in Portuguese and names each medicine " \
        "by its active ingredient, never by a brand: write the query in Portuguese, turning a brand into its " \
        "active ingredient and an English or Spanish name into the Portuguese one (amoxicillin is amoxicilina). " \
        "Typos are tolerated. Each product comes with its price, its stock (0 is out of stock) and whether it " \
        "requires a prescription, which is presented at the counter. Each also comes with its match: exact when " \
        "every word of the query is in it; close when it only resembles the query; partial when only some words " \
        "of the query are in it, listed only when nothing matches the whole query. A close match may be another " \
        "medicine with a similar name (omeprazol for esomeprazol). Name a close or partial product by its own " \
        "name, never as what the visitor asked for unless it plainly is, and never offer a different active " \
        "ingredient in place of the one asked for: that is a substitution, which only the pharmacist decides. " \
        "An empty list means the pharmacy does not carry it: say so, offer the pharmacist on duty, and never " \
        "name a product the results do not list."
    input_schema Input

    # The arguments are read as the model sent them: a typed reader raises on
    # a value its type cannot take, which would make a bad argument a bug.
    def perform(input)
      query = input.to_h[:query]
      query = query.is_a?(String) ? query.gsub(/[[:cntrl:]]/, " ").squish : ""
      raise Error, EMPTY if query.empty?
      raise Error, LONG if query.length > MAX_QUERY

      products = Product.search(query, limit: limit(input))
      { "query" => query, "products" => products.map { |product| entry(product) } }
    end

    private

    def limit(input)
      (Integer(input.to_h[:limit], exception: false) || MAX_RESULTS).clamp(1, MAX_RESULTS)
    end

    def entry(product)
      {
        "id" => product.id, "name" => product.name, "active_ingredient" => product.active_ingredient,
        "price" => ActiveSupport::NumberHelper.number_to_currency(product.price, locale: :"pt-BR"),
        "stock" => product.stock, "prescription_required" => product.prescription_required,
        "match" => product.match, "score" => product.score
      }
    end
  end
end
