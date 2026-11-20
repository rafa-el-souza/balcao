# What the history gives the model back of a turn (AgentRunner::History;
# design §10, M2-11a): the tool calls the model made and their results, the
# reply as it wrote it, its tags included, and which fixed text the system
# sent in its place when it answered instead (the owner, 2026-11-20). The
# tool exchange and the reply are encrypted (threat model SR-41: a tool
# call's input and a reply may quote what the visitor sent). The columns are
# new and nullable: an image still serving while Kamal runs this in the new
# container writes none of them, and the history reads a turn without them by
# its reply's text (Message#authored).
class KeepWhatTheModelRead < ActiveRecord::Migration[8.1]
  def change
    add_column :turns, :tool_exchange, :text
    add_column :turns, :model_reply, :text
    add_column :turns, :reply_kind, :string
  end
end
