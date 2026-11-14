# Threat model SR-41 from PR-18: Message encrypts its body, and the messages
# stored before were written in plain text, which the model cannot read. Each
# is encrypted where it is, through a model of its own that still reads plain
# text; a body already encrypted is left as it is, so the migration can run
# again. The demo's seven-day retention keeps the table small. Nothing to
# undo: decrypting would put visitors' words back in plain text.
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

  def down; end
end
