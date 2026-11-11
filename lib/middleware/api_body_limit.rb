module Balcao
  # Threat model SR-04: a body over 16 KB to the public API is refused here,
  # before any controller runs, so nothing parses it or writes it to the log
  # (review finding V1 of pull request #12). The proxy has refused anything
  # over 1 MB before (config/deploy.yml); Puma gives every body its length.
  class ApiBodyLimit
    MAX = 16 * 1024
    PREFIX = "/api/".freeze

    def initialize(app)
      @app = app
    end

    def call(env)
      return @app.call(env) unless env["PATH_INFO"].to_s.start_with?(PREFIX) && env["CONTENT_LENGTH"].to_i > MAX

      [ 413, { "content-type" => "application/json; charset=utf-8", "cache-control" => "no-store" }, [ %({"error":"size"}) ] ]
    end
  end
end
