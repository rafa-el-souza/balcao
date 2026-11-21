# The answers no route's endpoint writes, as threat model SR-03 lists them:
# what each is called and the status the application answers it with.
# spec/requests/response_headers_spec.rb asks each of the application
# itself, under the production configuration, and bin/edge-check asks a
# deployed host from outside, through its proxy (design §9.2's M3 list,
# built in M3-6), so the two read one list.
module EdgeCheck
  CATALOGUE = {
    "an unknown path" => 404, "a route's constraint not met" => 404, "another host" => 403, "a static file" => 200,
    "a body over 16 KB" => 413, "a request past the edge's limit" => 429,
    "the cable's handshake of another version" => 426, "the cable's handshake without a key" => 400,
    "the cable's socket past a source's cap" => 429, "the cable's socket past the process's cap" => 503
  }.freeze

  # What one request from outside cannot reach: the caps count 20 sockets of
  # a source and 500 of the process (SR-40), which the inside spec lowers on
  # the mounted gate itself.
  INSIDE_ONLY = [ "the cable's socket past a source's cap", "the cable's socket past the process's cap" ].freeze

  # What the edge answers by itself, without SR-03's set, accepted (threat
  # model SR-03): kamal-proxy's redirect of plain HTTP and its own page for a
  # host it does not serve, which reflects nothing of the request and which
  # a browser never meets on the demo's name (its TLS name and its Host are
  # the same), seen from outside first in M3-6; Thruster's bodiless 502 and
  # Puma's own 500, which no request can cause on demand (ADR-0020; pull
  # request #40, C2). The application's own 403 for another host is the
  # inside spec's: through the proxy, the proxy answers first.
  EDGE = {
    "the proxy's redirect to HTTPS" => 301, "the proxy's page for a host it does not serve" => 404
  }.freeze
  ACCEPTED = [ "Thruster's bodiless 502", "Puma's own 500" ].freeze
end
