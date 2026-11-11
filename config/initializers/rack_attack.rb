# FR-14's per-IP and per-visitor limits at the edge (threat model SR-01,
# SR-36). app/models/edge_limits.rb holds the numbers, says which requests
# count and counts them in rolling windows; a request past a limit gets the
# fixed reply. The health check, the web app's shell and its static files are
# not counted, nor is the operator console (M2).
Rack::Attack.cache.store = Rails.cache

# The API's 16 KB body limit runs after the edge has counted the request, so
# an oversized body counts against its source too (threat model SR-04, SR-01;
# review finding V4 of pull request #12), and before any controller.
Rails.application.config.middleware.insert_after Rack::Attack, Balcao::ApiBodyLimit

Rack::Attack.blocklist("ip/requests") do |request|
  EdgeLimits.api?(request) && EdgeLimits.from_app?(request) && EdgeLimits.over?("ip/requests", EdgeLimits.source_of(request))
end
Rack::Attack.blocklist("ip/anonymous") do |request|
  EdgeLimits.api?(request) && !EdgeLimits.from_app?(request) && EdgeLimits.over?("ip/anonymous", EdgeLimits.source_of(request))
end
Rack::Attack.blocklist("ip/sessions") do |request|
  EdgeLimits.new_session?(request) && EdgeLimits.over?("ip/sessions", EdgeLimits.source_of(request))
end
Rack::Attack.blocklist("ip/turns") do |request|
  EdgeLimits.turn?(request) && EdgeLimits.over?("ip/turns", EdgeLimits.source_of(request))
end
Rack::Attack.blocklist("visitor/minute") do |request|
  EdgeLimits.turn?(request) && EdgeLimits.over?("visitor/minute", EdgeLimits.visitor(request))
end
Rack::Attack.blocklist("visitor/day") do |request|
  EdgeLimits.turn?(request) && EdgeLimits.over?("visitor/day", EdgeLimits.visitor(request))
end

Rack::Attack.blocklisted_responder = ->(request) { EdgeLimits.response(request.env) }
