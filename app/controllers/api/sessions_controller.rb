module Api
  # POST /api/session (FR-18): issues the visitor cookie, or renews the one
  # the page brought back, and answers the open conversation, with the
  # month's budget mode and the rate of the real that the glass box shows
  # (FR-12, FR-14).
  #
  # A request that mints an identity, one without a cookie whose signature
  # verifies, needs the token of Turnstile's widget, which Cloudflare's
  # siteverify accepts (SR-39, ADR-0012): else it is refused with "challenge",
  # the page's hint to try the check again, and nothing is created. A page
  # that brings back its cookie mints nothing and needs none, as the per-IP
  # limit on new sessions counts only a request that would mint, refused or
  # not (SR-01, EdgeLimits.new_session?); its token, if it sent one, is not
  # asked about.
  class SessionsController < BaseController
    def create
      body = request.content_length.to_i.zero? ? {} : json_body
      language = requested_language(body)
      token = WebSession.issue(request, token: WebSession.token(request) || minted(body))
      visitor = Visitor.identify!(channel: "web", identity_hash: WebSession.identity_hash(token))
      conversation = Conversation.current_for!(visitor)
      conversation.update!(language:) if language && !conversation.messages.outbound.exists?

      render json: { conversation_id: conversation.id, trace_token: conversation.trace_token,
                     language: conversation.language, mode: Budget.mode, brl: Prices.brl_payload }, status: :created
    end

    private

    # A new identity's token, once Turnstile's check passed (SR-39).
    def minted(body)
      refuse!(:forbidden, "challenge") unless Turnstile.passed?(body["turnstile_token"])
      SecureRandom.base58(24)
    end

    # The page's language, for a conversation not yet answered (FR-02): one
    # of the three, else nothing.
    def requested_language(body)
      language = body["language"]
      language if language.is_a?(String) && I18n.available_locales.map(&:to_s).include?(language)
    end
  end
end
