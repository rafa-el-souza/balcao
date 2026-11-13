module Tools
  # Units of one catalogue product held for the visitor to pick up at the
  # counter (FR-07, design §6.6). The runner gives the tool its turn, so the
  # visitor and the key never come from the model (SR-16): a reservation is
  # keyed by the turn and the product (NFR-02), and the tool looks that key up
  # before anything else, so a turn that asks again, with a new tool_use id
  # after a model error, a timeout or a deploy, gets the reservation it
  # already made, whatever the stock or the cap say now (review finding RN2 of
  # pull request #7).
  #
  # Then every argument is checked again on the server, as the schema cannot
  # bound them (SR-16), and each rule refuses with its reason code (the
  # drawings' reason code, design §10): a product that requires a
  # prescription is never reserved, since it is sold only against the
  # prescription presented at the counter (FR-07, as the owner read it on
  # 2026-11-13: the search gives its price and flag, and the model calls
  # nothing more); at most MAX_QUANTITY units per reservation and MAX_OPEN
  # open reservations per visitor; never more than the stock.
  #
  # One transaction holds the visitor's row, counts what it holds, stores the
  # reservation and takes its units by a relative decrement that never goes
  # below zero, so two reservations of the last units cannot both have them,
  # and a stock the seed writes meanwhile keeps the units (CatalogueSeed,
  # FR-15). The pickup deadline is the end of the next business day
  # (StoreSheet#pickup_until).
  class CreateReservation < AgentTool
    MAX_QUANTITY = 10
    MAX_OPEN = 3
    ID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    REASONS = %w[unknown_product prescription invalid_quantity over_limit open_limit low_stock out_of_stock].freeze

    class Input < Anthropic::BaseModel
      required :product_id, String, doc: "The id of the product, as search_products returned it."
      required :quantity, Integer, doc: "How many units to reserve, from 1 to #{MAX_QUANTITY}."
    end

    UNKNOWN = "No product in the catalogue has this id. Search with search_products and use the id of a product " \
              "it returns.".freeze
    QUANTITY = "The quantity must be a whole number of units, at least 1. Ask the visitor how many units they " \
               "want.".freeze
    PRESCRIPTION = "This product requires a prescription, so it is not reserved: it is sold only against the " \
                   "prescription presented at the counter. Tell the visitor so, with its price.".freeze
    OVER_LIMIT = "The quantity is over the limit of #{MAX_QUANTITY} units per reservation. Offer #{MAX_QUANTITY} " \
                 "units, or the pharmacist on duty for a larger order.".freeze
    OUT_OF_STOCK = "This product is out of stock, so nothing was reserved. Tell the visitor, and offer the " \
                   "pharmacist on duty.".freeze
    LOW_STOCK = "Only %<units>s in stock, fewer than asked, so nothing was reserved. Offer %<units>s.".freeze
    OPEN_LIMIT = "The visitor already holds #{MAX_OPEN} open reservations, the most allowed, so nothing was " \
                 "reserved. Tell the visitor, and list the ones they hold: %<held>s".freeze

    doc "Reserve units of one catalogue product for the visitor to pick up at the counter. Call it only when the " \
        "visitor asks to reserve, with the id of the product they chose from search_products (search first when " \
        "you do not have it) and the number of units they asked for; when the request could be more than one " \
        "product, ask which before reserving. Never call it for a product that requires a prescription: it is " \
        "not reserved, since it is sold only against the prescription presented at the counter; tell the visitor " \
        "so, with its price. A reservation holds 1 to #{MAX_QUANTITY} units, and a visitor holds at most " \
        "#{MAX_OPEN} open reservations. The result is the reservation: tell the visitor its code, which they show " \
        "at the counter, the quantity, the product and the pickup deadline (pickup_until, São Paulo time, the end " \
        "of the next business day). When the tool refuses, its message says why and what to offer instead: tell " \
        "the visitor, and never say that anything was reserved."
    input_schema Input

    # The stock fell below the units between the check and the decrement.
    class Shortage < StandardError; end
    private_constant :Shortage

    # The arguments are read as the model sent them: a typed reader raises on
    # a value its type cannot take, which would make a bad argument a bug.
    def perform(input)
      product_id = input.to_h[:product_id]
      refuse(UNKNOWN, "unknown_product") unless product_id.is_a?(String) && product_id.match?(ID)

      product_id = product_id.downcase
      held = Reservation.find_by(turn_id: turn.id, product_id:)
      return result(held) if held

      product = Product.find_by(id: product_id, listed: true) or refuse(UNKNOWN, "unknown_product")
      refuse(PRESCRIPTION, "prescription") if product.prescription_required
      result(reserve(product, quantity(input)))
    end

    private

    def quantity(input)
      quantity = input.to_h[:quantity]
      refuse(QUANTITY, "invalid_quantity") unless quantity.is_a?(Integer) && quantity.positive?
      refuse(OVER_LIMIT, "over_limit") if quantity > MAX_QUANTITY

      quantity
    end

    def reserve(product, quantity)
      Reservation.transaction do
        visitor = Visitor.lock.find(turn.conversation.visitor_id)
        held = Reservation.held_by(visitor).includes(:product).order(:created_at, :id).to_a
        refuse(format(OPEN_LIMIT, held: JSON.generate(held.map { |reservation| result(reservation) })), "open_limit") if held.size >= MAX_OPEN

        reservation = Reservation.create_once!(turn:, product:, quantity:, pickup_until: StoreSheet.current.pickup_until(Time.current))
        take(product, quantity) if reservation.previously_new_record?
        reservation
      end
    rescue Shortage
      stock = Product.where(id: product.id).pick(:stock).to_i
      stock.positive? ? refuse(format(LOW_STOCK, units: units(stock)), "low_stock") : refuse(OUT_OF_STOCK, "out_of_stock")
    end

    # The units leave the stock as it is in the database, never below zero;
    # when they are not there, the reservation goes back with the transaction.
    def take(product, quantity)
      taken = Product.where(id: product.id).where("stock >= ?", quantity)
                     .update_all([ "stock = stock - ?, updated_at = ?", quantity, Time.current ])
      raise Shortage if taken.zero?
    end

    def units(count) = count == 1 ? "1 unit" : "#{count} units"

    def result(reservation)
      { "code" => reservation.code, "quantity" => reservation.quantity, "product" => reservation.product.name,
        "pickup_until" => reservation.pickup_until.in_time_zone.iso8601 }
    end
  end
end
