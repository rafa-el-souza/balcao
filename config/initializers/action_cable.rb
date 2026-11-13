# The cable accepts the web app's origin only (threat model SR-03), and not
# also an origin equal to the request's own Host, which Action Cable accepts
# by default and production's host check alone would have refused; the
# connection reads the visitor cookie (app/channels/application_cable).
Rails.application.config.action_cable.allowed_request_origins = [ Rails.configuration.x.public_origin ]
Rails.application.config.action_cable.allow_same_origin_as_host = false

# The cable is mounted behind its gate in config/routes.rb (ADR-0015).
Rails.application.config.action_cable.mount_path = nil

