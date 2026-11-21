# SR-20's hard edge of a turn's run (threat model SR-20; design §10, M3-4):
# the moment by which every model call of the turn, FR-20's check's included,
# and every tool call has ended. TurnProcessor sets it when the model's work
# starts, sixty seconds on (AgentRunner::WALL_CLOCK), or FR-17's canary's
# twenty, so a slow model ends a canary's turn at the canary's own time.
# AgentRunner and Guardrail give each attempt of a model call only what is
# left of it (ModelAttempts) and AgentRunner refuses a tool call past it; the
# turn then ends at its deadline, with the fallback (NFR-03).
#
# deadline is a reading of clock, the monotonic clock in production.
TurnEdge = Data.define(:deadline, :clock) do
  def self.after(seconds, clock: AgentRunner::MONOTONIC) = new(deadline: clock.call + seconds, clock:)

  def remaining = deadline - clock.call

  def passed? = !remaining.positive?
end
