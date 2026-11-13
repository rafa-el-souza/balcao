module ApplicationCable
  # The cable reads the visitor cookie the API set (design FR-18, threat model
  # SR-03), and knows the source address its subscriptions count against
  # (SR-01, SR-11). A page without the cookie may still follow a trace by its
  # token (FR-12), so the connection is open to it, with no visitor.
  class Connection < ActionCable::Connection::Base
    # SR-40, ADR-0015: a page sends one or two commands on its socket.
    COMMANDS_PER_MINUTE = 20

    identified_by :identity_hash, :source

    def connect
      self.identity_hash = WebSession.identity_hash_of(cookies)
      self.source = EdgeLimits.source(request.env)
    end

    # Every message the socket reads comes through here, from the event loop,
    # before Action Cable's message buffer and its worker pool, whose queue has
    # no bound (spec/channels/command_limit_spec.rb pins that path). Past the
    # minute's commands the connection is closed for good: a page never gets
    # there, and a client told to reconnect would only start over.
    def on_message(message)
      return super unless over_command_limit?

      logger.info "Closing the connection: more than #{COMMANDS_PER_MINUTE} commands in a minute"
      close(reason: "limit", reconnect: false)
    end

    private

    # A minute starts at the first command after the last one ended, as the
    # edge's limits count (app/models/edge_limits.rb).
    def over_command_limit?
      now = Time.current
      if @commands_since.nil? || now - @commands_since >= 1.minute
        @commands_since = now
        @commands = 0
      end
      (@commands += 1) > COMMANDS_PER_MINUTE
    end
  end
end
