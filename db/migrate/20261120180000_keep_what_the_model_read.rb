# What the history gives the model back of a turn (AgentRunner::History;
# design §10, M2-11a): the tool calls the model made and their results, and
# how much of the stored reply the model wrote, so that the system's fixed
# texts are marked as the system's. The tool exchange is encrypted (threat
# model SR-41: a tool call's input may quote what the visitor sent). Both
# columns are new and nullable: an image still serving while Kamal runs this
# in the new container writes neither, and the history reads a row without
# them as it read every row before.
class KeepWhatTheModelRead < ActiveRecord::Migration[8.1]
  def change
    add_column :turns, :tool_exchange, :text
    add_column :messages, :attendant_characters, :integer
  end
end
