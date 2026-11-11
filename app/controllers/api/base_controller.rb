# The public API's ground rules (design §6.6, threat model SR-03, SR-04,
# SR-05):
#
# - the visitor is the one the signed cookie names (WebSession), never an id
#   the request sends, and every query is scoped by it;
# - a state-changing request must come from the public origin;
# - a body is JSON, read here and nowhere before (Rails reads no JSON body as
#   parameters, config/initializers/parameter_parsers.rb), and checked against
#   the endpoint's schema.
#
# Before any of this, at the edge: the per-IP and per-visitor limits
# (config/initializers/rack_attack.rb) and the 16 KB body limit
# (lib/middleware/api_body_limit.rb).
module Api
  class BaseController < ApplicationController
    include ActionController::Cookies

    class Refused < StandardError
      attr_reader :status, :code

      def initialize(status, code)
        @status = status
        @code = code
        super(code)
      end
    end

    # The body is read here, not by Rails' wrapper.
    wrap_parameters false

    before_action :verify_origin, unless: -> { request.get? || request.head? }

    rescue_from Refused do |refused|
      render json: { error: refused.code }, status: refused.status
    end

    private

    def verify_origin
      refuse!(:forbidden, "origin") unless request.origin == Rails.configuration.x.public_origin
    end

    def refuse!(status, code) = raise(Refused.new(status, code))

    # The request's JSON object; the edge has refused a body over 16 KB.
    def json_body
      refuse!(:unsupported_media_type, "content_type") unless request.media_type == "application/json"

      body = JSON.parse(request.raw_post.to_s.dup.force_encoding(Encoding::UTF_8).scrub)
      refuse!(:unprocessable_content, "schema") unless body.is_a?(Hash)
      body
    rescue JSON::ParserError
      refuse!(:bad_request, "json")
    end

    # The hash of the cookie's token; a request without the cookie is refused.
    def require_session!
      WebSession.identity_hash_of(cookies) or refuse!(:unauthorized, "session")
    end

    # The cookie's visitor. Nil when it deleted its data (FR-05) or the
    # nightly job purged it (FR-15).
    def cookie_visitor = Visitor.find_by(channel: "web", identity_hash: require_session!)
  end
end
