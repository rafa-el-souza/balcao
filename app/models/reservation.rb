# Units of a product held for a visitor until pickup (FR-07).
class Reservation < ApplicationRecord
  # Read aloud at the counter: no 0/O, 1/I/L or U.
  CODE_ALPHABET = "23456789ABCDEFGHJKMNPQRSTVWXYZ".freeze
  CODE_LENGTH = 6
  CODE_ATTEMPTS = 5

  belongs_to :visitor
  belongs_to :product

  enum :state, { open: "open", expired: "expired", cancelled: "cancelled" }, validate: true

  validates :code, :idempotency_key, :pickup_until, presence: true
  validates :quantity, numericality: { only_integer: true, greater_than: 0 }

  # Creates the reservation keyed by the SDK tool_use id of the call that asked
  # for it. A replayed call meets the unique index and gets the reservation
  # already made, which the caller recognises by previously_new_record? being
  # false and must not take stock for again (NFR-02, FR-07).
  #
  # The code has its own unique index. When that one refuses the row, Rails
  # finds no reservation under the key and raises RecordNotFound; a new code
  # is drawn, a few times at most.
  def self.create_once!(idempotency_key:, **attributes)
    attempts = 0
    begin
      attempts += 1
      create_or_find_by!(idempotency_key:) do |reservation|
        reservation.assign_attributes(attributes)
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
