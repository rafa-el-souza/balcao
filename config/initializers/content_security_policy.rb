# Threat model SR-03: a strict policy on every response, the web app's shell
# above all. No inline script, no eval, nothing from a third party: the MVP
# has none (Turnstile's origin joins with SR-39 after the MVP, design FR-18's
# MVP note). The cable is named in connect-src beside 'self' for browsers
# that do not read 'self' as covering ws:/wss:. In development the shell
# comes from the Vite dev server, which sends no policy.
Rails.application.config.content_security_policy do |policy|
  cable = Rails.configuration.x.public_origin.sub(/\Ahttp/, "ws")

  policy.default_src :self
  policy.script_src :self
  policy.style_src :self
  policy.img_src :self, :data
  policy.font_src :self
  policy.connect_src :self, cable
  policy.object_src :none
  policy.base_uri :none
  policy.form_action :self
  policy.frame_ancestors :none
end
