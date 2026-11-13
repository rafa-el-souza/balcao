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

    # The socket is closed or closing (app/channels/application_cable/channel.rb).
    def gone? = !websocket.alive?

    # Every message the socket reads comes through here, from the event loop,
    # before Action Cable's message buffer and its worker pool, whose queue has
    # no bound (spec/channels/command_limit_spec.rb pins that path). Past the
    # minute's commands the connection is closed for good: a page never gets
    # there, and a client told to reconnect would only start over.
    def on_message(message)
      return super unless over_command_limit?

      logger.info "Closing the connection: more than #{COMMANDS_PER_MINUTE} commands in a minute"
      close(reason: "limit", reconnect: false)
      # Closing waits for the client's answer, with the socket open and its
      # driver reading whatever comes, no longer held to 16 KiB a frame; the
      # socket is shut here instead (review finding V1 of pull request #23).
      driver = env[Balcao::CableDriver::DRIVER]
      Balcao::CableDriver.shut(driver, "more than #{COMMANDS_PER_MINUTE} commands in a minute") if driver
    end

    private

    # Action Cable runs a socket's opening and its closing as two tasks of its
    # worker pool, and the opening adds the connection to the server's list of
    # connections at its very end: a socket closed right after its 101 may see
    # its closing run first, find nothing to remove, and leave the connection
    # in the list until the process ends (measured: 52 of 1,000). One whose
    # socket is gone by the end of its opening leaves the list here
    # (spec/channels/connection_list_spec.rb pins the methods).
    def handle_open
      super
      server.remove_connection(self) unless websocket.alive?
    end

    # The opening also subscribes the connection's internal channel, whose
    # only use is to disconnect it from another process, which this app never
    # does; its callback holds the connection. Action Cable posts the subscribe
    # and the closing's unsubscribe to a pool of threads with no order between
    # them, so a socket closed at once left the subscription, and the
    # connection, in the pub/sub until the process ended (measured: 49 of
    # 1,000; reported by another session on the list fix). No internal
    # channel is subscribed. Whoever needs a remote disconnect removes this,
    # and that race comes back with it.
    def subscribe_to_internal_channel = nil

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
