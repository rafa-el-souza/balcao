# The cable accepts the web app's origin only (threat model SR-03), and not
# also an origin equal to the request's own Host, which Action Cable accepts
# by default and production's host check alone would have refused; the
# connection reads the visitor cookie (app/channels/application_cable).
Rails.application.config.action_cable.allowed_request_origins = [ Rails.configuration.x.public_origin ]
Rails.application.config.action_cable.allow_same_origin_as_host = false

# The cable is mounted behind its gate in config/routes.rb (ADR-0015).
Rails.application.config.action_cable.mount_path = nil

# The WebSocket driver Action Cable builds for each socket (websocket-driver
# 0.8.2; ADR-0015).
#
# Threat model SR-04 (option A): Action Cable builds it with no size limit, so
# websocket-driver's own applies, 64 MiB a message, buffered whole before
# anything reads it. It takes 16 KiB: a longer message closes the socket with
# 1009, from the frame's header. A page's command is about a hundred bytes.
# Action Cable has no setting for it; when Rails ships one, this goes.
#
# SR-40: a ping or a pong from the client fails the connection at once. A
# browser sends neither (the cable's pings are messages of its own), and
# websocket-driver answers each ping at once, into Action Cable's write
# buffer, which has no bound when the client does not read; neither reaches
# the count of commands (review finding C2 of pull request #23).
require "websocket/driver"

module Balcao
  module CableDriver
    MAX_MESSAGE = 16 * 1024

    # Fails the connection as websocket-driver fails it for a frame too long:
    # a close frame if none was sent yet (1008), the parser stopped, and the
    # socket shut, so nothing more is read from the client, however much it
    # sends. The method is websocket-driver's own, private; a spec pins it.
    def self.shut(driver, reason) = driver.send(:shutdown, 1008, reason)

    def rack(socket, options = {})
      driver = super(socket, options.merge(max_length: [ options[:max_length] || MAX_MESSAGE, MAX_MESSAGE ].min))
      %i[ping pong].each { |event| driver.on(event) { CableDriver.shut(driver, "no #{event}s") } }
      driver
    end
  end
end

WebSocket::Driver.singleton_class.prepend(Balcao::CableDriver)
