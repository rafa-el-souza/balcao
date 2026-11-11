module ApplicationCable
  class Channel < ActionCable::Channel::Base
    private

    # Each subscription looks a row up, so each counts as a request of the
    # connection's source against the per-IP limit (FR-14, threat model
    # SR-01, SR-11).
    def over_limit? = EdgeLimits.over?("ip/requests", connection.source)
  end
end
