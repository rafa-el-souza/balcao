module ApplicationCable
  # The cable's front door, mounted at /cable in front of Action Cable
  # (config/routes.rb; ADR-0015). It answers here, in plain HTTP and before
  # Action Cable takes the socket over:
  #
  # - a handshake that is not RFC 6455's (threat model SR-04): another version,
  #   or none, which websocket-driver would read as hixie-75 or -76, whose
  #   parser costs about 90 times the CPU per byte on the cable's one event
  #   loop; or no key, which Action Cable would take over before refusing;
  # - a socket past the caps (SR-40): Puma has 1,024 files on the host, each
  #   socket holds one, and about 1,000 idle sockets stopped it answering. A
  #   refusal here holds nothing, and the page's cable client tries again by
  #   itself a few seconds later; a refusal after the takeover would leave the
  #   socket open for as long as the client keeps it.
  #
  # The caps count the sockets Action Cable took over and has not closed yet,
  # by the socket itself: Action Cable's own list of connections kept one now
  # and then that closed as it opened (measured: 21 of 300). A handshake
  # holds its place from the check until the cable has taken its socket or
  # not, so handshakes at once never share the last place (review finding C3
  # of pull request #23).
  class Gate
    VERSION = "13"
    # Per process: config/puma.rb runs one, with no workers.
    MAX_SOCKETS = 500
    # Per source, the client's address as the edge counts it (SR-36).
    MAX_SOCKETS_PER_SOURCE = 20

    HEADERS = { "content-type" => "application/json; charset=utf-8", "cache-control" => "no-store" }.freeze

    def initialize(cable, max: MAX_SOCKETS, per_source: MAX_SOCKETS_PER_SOURCE)
      @cable = cable
      @max = max
      @per_source = per_source
      @lock = Mutex.new
      @sockets = {}.compare_by_identity # each socket taken over => its source
      @pending = Hash.new(0) # source => handshakes between the check and the takeover
    end

    def call(env)
      return @cable.call(env) unless WebSocket::Driver.websocket?(env)
      return refuse(426, "version", "sec-websocket-version" => VERSION) unless env["HTTP_SEC_WEBSOCKET_VERSION"] == VERSION
      return refuse(400, "key") if env["HTTP_SEC_WEBSOCKET_KEY"].to_s.strip.empty?

      source = EdgeLimits.source(env)
      full = hold_place(source)
      return refuse(full == :busy ? 503 : 429, full.to_s) if full

      take_over(env, source)
    end

    private

    # Answers :busy or :limit past a cap; otherwise holds a place for the
    # source until take_over lets it go.
    def hold_place(source)
      @lock.synchronize do
        @sockets.delete_if { |socket, _| socket.closed? }
        if @sockets.size + @pending.sum { |_, count| count } >= @max then :busy
        elsif @sockets.count { |_, holder| holder == source } + @pending[source] >= @per_source then :limit
        else
          @pending[source] += 1
          nil
        end
      end
    end

    # Calls the cable, keeping the socket it takes over, if it does, in the
    # place its handshake held.
    def take_over(env, source)
      socket = nil
      if (hijack = env["rack.hijack"])
        env["rack.hijack"] = -> { socket = hijack.call }
      end
      @cable.call(env)
    ensure
      @lock.synchronize do
        @pending.delete(source) if (@pending[source] -= 1).zero?
        @sockets[socket] = source if socket && !socket.closed?
      end
    end

    def refuse(status, error, headers = {})
      [ status, HEADERS.merge(headers), [ { error: }.to_json ] ]
    end
  end
end
