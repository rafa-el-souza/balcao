# Units of a product held for a visitor until pickup (FR-07).
class Reservation < ApplicationRecord
  # Read aloud at the counter: no 0/O, 1/I/L or U.
  CODE_ALPHABET = "23456789ABCDEFGHJKMNPQRSTVWXYZ".freeze
  CODE_LENGTH = 6
  CODE_ATTEMPTS = 5

  belongs_to :visitor
  # Emptied when the purge takes the turn's conversation; the reservation stays.
  belongs_to :turn, optional: true
  belongs_to :product

  enum :state, { open: "open", expired: "expired", cancelled: "cancelled" }, validate: true

  validates :code, :pickup_until, presence: true
  validates :quantity, numericality: { only_integer: true, greater_than: 0 }

  # Creates the reservation that this turn asks for of this product, for the
  # turn's visitor. The turn and the product are the key (NFR-02): a turn run
  # again after a model error, a timeout or a deploy calls the model again,
  # and the API sends a new tool_use id for the same request, so that id
  # cannot be the key. A second call meets the unique index and gets the
  # reservation already made, which the caller recognises by
  # previously_new_record? being false and must not take stock for again
  # (FR-07). The runner injects the turn and the tool validates the product,
  # so no free value the model writes enters the key (SR-16).
  #
  # The code has its own unique index. When that one refuses the row, Rails
  # finds no reservation under the key and raises RecordNotFound; a new code
  # is drawn, a few times at most.
  def self.create_once!(turn:, product:, **attributes)
    attempts = 0
    begin
      attempts += 1
      create_or_find_by!(turn_id: turn.id, product_id: product.id) do |reservation|
        reservation.assign_attributes(attributes)
        reservation.visitor_id = turn.conversation.visitor_id
        reservation.code = generate_code
      end
    rescue ActiveRecord::RecordNotFound
      retry if attempts < CODE_ATTEMPTS
      raise ActiveRecord::RecordNotUnique, "no free reservation code after #{CODE_ATTEMPTS} draws"
    end
  end

  def self.generate_code
    Array.new(CODE_LENGTH) { CODE_ALPHABET[SecureRandom.random_number(CODE_ALPHABET.length)] }.join
  end
end
