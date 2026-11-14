# Threat model SR-41 from PR-18: Message encrypts its body, and the messages
# stored before were written in plain text. Each is encrypted where it is,
# through a model of its own that still reads plain text; a body already
# encrypted is left as it is, so the migration can run again. The demo's
# seven-day retention keeps the table small.
#
# A one-way door (review finding V1 of pull request #32): an image before
# PR-18 shows the stored bodies' ciphertext and sends it to the model, so a
# deploy goes back no further than PR-18, and rolling this back raises
# rather than look undone, decrypting being no fix. What such an image
# writes meanwhile is plain text, which Message reads as written and the
# nightly job encrypts.
class EncryptMessageBodies < ActiveRecord::Migration[8.1]
  class StoredMessage < ActiveRecord::Base
    self.table_name = "messages"
    encrypts :body, support_unencrypted_data: true
  end

  def up
    StoredMessage.find_each do |message|
      message.encrypt unless message.encrypted_attribute?(:body)
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "the message bodies stay encrypted (threat model SR-41)"
  end
end
