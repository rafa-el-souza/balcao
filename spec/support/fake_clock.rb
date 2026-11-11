# A monotonic clock the examples move by hand, for the turn's wall clock
# (threat model SR-20); travel_to moves wall time, not the monotonic clock.
class FakeClock
  def initialize = @now = 0.0
  def call = @now
  def advance(seconds) = @now += seconds
end
