# A WhatsApp event as Meta sent it, stored before any processing (FR-19, SR-09).
class WebhookEvent < ApplicationRecord
  has_many :messages

  enum :status, { received: "received", processed: "processed", ignored: "ignored", failed: "failed" },
       validate: true

  validates :body_sha256, format: { with: /\A\h{64}\z/ }
  validates :received_at, presence: true
  validates :payload, exclusion: { in: [ nil ] }

  # Stores the event keyed by the SHA-256 of the raw body whose signature the
  # caller has verified (SR-06). A redelivered POST meets the unique index and
  # returns the event already stored, which the caller recognises by
  # previously_new_record? being false (SR-07, NFR-02). The key is the body,
  # not Meta's message id, because the sent, delivered and read notifications
  # of one message share that id (review finding C3 of pull request #7); the
  # messages an event yields are keyed by that id (Message.record_inbound!).
  def self.record!(raw_body:, received_at: Time.current)
    payload = JSON.parse(raw_body)
    create_or_find_by!(body_sha256: Digest::SHA256.hexdigest(raw_body)) do |event|
      event.payload = payload
      event.received_at = received_at
    end
  end
end
