# What the history gives the model back of a turn (AgentRunner::History;
# design §10, M2-11a): the tool calls the model made and their results, and
# where the model's words begin in the stored reply and how long they are, so
# that the system's fixed texts are marked as the system's whatever reply the
# purge left first (review finding H-B2 of pull request #60). The tool
# exchange is encrypted (threat model SR-41: a tool call's input may quote
# what the visitor sent). The columns are new and nullable: an image still
# serving while Kamal runs this in the new container writes none of them, and
# the history reads a row without them by its text (Message#authored).
class KeepWhatTheModelRead < ActiveRecord::Migration[8.1]
  def change
    add_column :turns, :tool_exchange, :text
    add_column :messages, :attendant_start, :integer
    add_column :messages, :attendant_characters, :integer
  end
end
