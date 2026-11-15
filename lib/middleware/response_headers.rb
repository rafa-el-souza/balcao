module Balcao
  # Threat model SR-03: every answer the application writes carries the
  # headers a controller's answer carries: Rails' default headers with the
  # Permissions-Policy (config/application.rb), and the Content-Security-Policy
  # (config/initializers/content_security_policy.rb). A controller's answer
  # has them when it is made; the answers written elsewhere did not (#36's
  # probe of the production configuration): the static files
  # (ActionDispatch::Static), the error page of an unknown path
  # (ActionDispatch::ShowExceptions), the refusal of another host
  # (ActionDispatch::HostAuthorization), and what Rack endpoints and
  # middleware write themselves: the cable gate's refusals and Action Cable's,
  # the edge's 413 and 429, the old trace link's redirect.
  #
  # So one middleware, at the top of the stack, which every answer crosses,
  # completes what an answer lacks of the set and never overrides a header
  # the answer carries (the trace page's referrer policy, the webhook's
  # own), rather than a patch in each of those places (the owner's word of
  # 2026-11-15, question 31). An answer with no policy gets the app's own,
  # built as Rails' middleware builds it for an answer that crosses that one
  # (ActionDispatch::ContentSecurityPolicy::Middleware), which the app gives
  # no nonce; a 304 gets none, as Rails gives it none, since a nonce may not
  # match the page the browser kept (design §10, the note of the first server
  # pull request of the MVP review). spec/requests/response_headers_spec.rb
  # walks every route and a catalogue of the rest.
  class ResponseHeaders
    POLICY = ActionDispatch::Constants::CONTENT_SECURITY_POLICY
    POLICY_REPORT_ONLY = ActionDispatch::Constants::CONTENT_SECURITY_POLICY_REPORT_ONLY

    def initialize(app)
      @app = app
    end

    def call(env)
      status, headers, body = @app.call(env)
      # A copy, so a frozen hash an endpoint answers with stays as it was.
      headers = Rack::Headers.new.merge!(headers)
      ActionDispatch::Response.default_headers.each { |name, value| headers[name] ||= value }
      policy(env, status, headers)
      [ status, headers, body ]
    end

    private

    def policy(env, status, headers)
      return if status == 304 || headers[POLICY] || headers[POLICY_REPORT_ONLY]

      request = ActionDispatch::Request.new(env)
      policy = request.content_security_policy or return
      name = request.content_security_policy_report_only ? POLICY_REPORT_ONLY : POLICY
      headers[name] = policy.build(request.controller_instance || request, request.content_security_policy_nonce,
                                   request.content_security_policy_nonce_directives)
    end
  end
end
