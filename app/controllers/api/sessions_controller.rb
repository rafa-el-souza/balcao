module Api
  # POST /api/session (FR-18): issues the visitor cookie, or renews the one
  # the page brought back, and answers the open conversation, with the
  # month's budget mode and the rate of the real that the glass box shows
  # (FR-12, FR-14). Until Turnstile ships after the MVP (SR-39), the per-IP
  # limit on new sessions is the gate (SR-01).
  class SessionsController < BaseController
    def create
      language = requested_language(request.content_length.to_i.zero? ? {} : json_body)
      token = WebSession.token(cookies)
      token = WebSession.issue(cookies, secure: request.ssl?, token: token || SecureRandom.base58(24))
      visitor = Visitor.identify!(channel: "web", identity_hash: WebSession.identity_hash(token))
      conversation = Conversation.current_for!(visitor)
      conversation.update!(language:) if language && !conversation.messages.outbound.exists?

      render json: { conversation_id: conversation.id, trace_token: conversation.trace_token,
                     language: conversation.language, mode: Budget.mode, brl: Prices.brl_payload }, status: :created
    end

    private

    # The page's language, for a conversation not yet answered (FR-02): one
    # of the three, else nothing.
    def requested_language(body)
      language = body["language"]
      language if language.is_a?(String) && I18n.available_locales.map(&:to_s).include?(language)
    end
  end
end
