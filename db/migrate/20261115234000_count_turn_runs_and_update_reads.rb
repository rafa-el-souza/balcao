# NFR-03's sweep (M4-4): a turn's runs and an update's reads are counted on
# their rows, each at the start of the work it counts, so a run or a read
# that kills its worker counts too, and the sweep that runs them again is
# bounded at three (TurnProcessor, TelegramUpdateJob; review findings of
# pull requests #11 and #18, and #32's H1 and H3).
#
# Additive, with defaults: an image before it, still serving while Kamal runs
# this in the new container, writes its rows as before, and a row it wrote
# reads as counted nothing yet.
class CountTurnRunsAndUpdateReads < ActiveRecord::Migration[8.1]
  def change
    add_column :turns, :runs, :integer, default: 0, null: false
    add_column :webhook_events, :reads, :integer, default: 0, null: false
  end
end
