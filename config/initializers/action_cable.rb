# The cable accepts the web app's origin only (threat model SR-03); the
# connection reads the visitor cookie (app/channels/application_cable).
Rails.application.config.action_cable.allowed_request_origins = [ Rails.configuration.x.public_origin ]
