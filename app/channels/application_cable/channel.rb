module ApplicationCable
  class Channel < ActionCable::Channel::Base
    # stream_from posts its pub/sub subscribe to the event loop's pool of
    # threads, with no order against the closing, which unsubscribes at once,
    # and a subscribe command and the closing run on different threads of the
    # worker pool: a channel subscribed and closed at once kept its stream for
    # good, holding the channel and its connection (review finding S1 of pull
    # request #23, threat model SR-40). Each stream is kept here too, and let
    # go once its subscribe is done if the channel or its socket is gone by
    # then (spec/channels/stream_lifetime_spec.rb pins what this relies on).
    def stream_from(broadcasting, ...)
      super
      handler = streams[broadcasting.to_s]
      (@held_streams ||= {})[broadcasting.to_s] = handler if handler
    end

    private

    # Each subscription looks a row up, so each counts as a request of the
    # connection's source against the per-IP limit (FR-14, threat model
    # SR-01, SR-11).
    def over_limit? = EdgeLimits.over?("ip/requests", connection.source)

    # Called once more for each stream, from the pub/sub, when its subscribe
    # is done, inside the pub/sub's lock: the streams go in a task of their
    # own, which finds them in.
    def ensure_confirmation_sent
      super
      return unless @held_streams && (unsubscribed? || connection.gone?)

      held = @held_streams
      connection.server.event_loop.post { held.each { |broadcasting, handler| pubsub.unsubscribe(broadcasting, handler) } }
    end
  end
end
