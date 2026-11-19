# A Telegram update as the webhook received it, stored before any processing
# and answered 200 (FR-19, threat model SR-09); TelegramUpdateJob reads it.
#
# - Keyed by Telegram's update_id, unique: an update sent again meets the
#   index and is the one already stored (SR-07, NFR-02). The id restarts at a
#   random value after a week without updates, so it keys and never counts.
# - The body is what a visitor sent, encrypted (SR-41), and only until its job
#   has read it, with the sender's hashed identity, by which a person's
#   unread updates are read in order (review finding T2 of pull request #32):
#   then the row keeps its update_id and its kind, and nothing of the person
#   or of their words, no digest included (FR-19; review finding RN3 of pull
#   request #7). The nightly job deletes a row seven days old, read or not
#   (FR-15).
class WebhookEvent < ApplicationRecord
  has_many :messages

  encrypts :payload

  enum :status, { received: "received", processed: "processed", ignored: "ignored", failed: "failed" },
       validate: true

  # The update's kind as Telegram names it ("message", "edited_message", ...).
  KIND = /\A[a-z_]{1,64}\z/

  validates :update_id, numericality: { only_integer: true }
  validates :kind, format: { with: KIND }
  validates :received_at, presence: true
  validates :identity_hash, format: { with: Visitor::IDENTITY_HASH }, allow_nil: true

  # A person's updates not read yet, in the order Telegram numbered them.
  scope :unread_of, ->(identity_hash) { received.where(identity_hash:).order(:update_id) }

  # Stores an update the webhook has authenticated (SR-06), or returns the one
  # already stored with this update_id, as it is (SR-07).
  def self.record!(update_id:, kind:, payload:, identity_hash: nil, received_at: Time.current)
    create_or_find_by!(update_id:) do |event|
      event.kind = kind
      event.payload = payload
      event.identity_hash = identity_hash
      event.received_at = received_at
    end
  end

  # The update as Telegram sent it, while it is unread.
  def update_hash = (JSON.parse(payload) if payload)

  # Read: the body goes, and with it everything the update said and whose it
  # was. Written as it is, never reading the stored body first, so an update
  # whose body no longer decrypts is stripped all the same (the hunter's H6
  # on pull request #48; update! decrypted the old value to compute its
  # change); the row's clock moves with it.
  def strip!(status) = update_columns(payload: nil, identity_hash: nil, status:, updated_at: Time.current)

  # The same for the update with this id, if it is still unread: a deletion
  # strips the update that asked for it (TurnProcessor, FR-05).
  def self.strip_unread!(id, status) = received.where(id:).update_all(payload: nil, identity_hash: nil, status:, updated_at: Time.current)
end
