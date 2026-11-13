# The cable accepts the web app's origin only (threat model SR-03), and not
# also an origin equal to the request's own Host, which Action Cable accepts
# by default and production's host check alone would have refused; the
# connection reads the visitor cookie (app/channels/application_cable).
Rails.application.config.action_cable.allowed_request_origins = [ Rails.configuration.x.public_origin ]
Rails.application.config.action_cable.allow_same_origin_as_host = false

# The cable is mounted behind its gate in config/routes.rb (ADR-0015).
Rails.application.config.action_cable.mount_path = nil

# Threat model SR-04, ADR-0015 (option A): Action Cable builds its WebSocket
# driver with no size limit, so websocket-driver's own applies, 64 MiB a
# message, buffered whole before anything reads it. The driver Action Cable
# builds takes 16 KiB: a longer message closes the socket with 1009, from the
# frame's header. A page's command is about a hundred bytes. Action Cable has
# no setting for it; when Rails ships one, this goes.
require "websocket/driver"

module Balcao
  module CableMessageLimit
    MAX = 16 * 1024

    def rack(socket, options = {}) = super(socket, options.merge(max_length: [ options.fetch(:max_length, MAX), MAX ].min))
  end
end

WebSocket::Driver.singleton_class.prepend(Balcao::CableMessageLimit)
