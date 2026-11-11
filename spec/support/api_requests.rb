# Requests as the web app sends them (design §6.6): JSON bodies from the
# public origin, with the visitor cookie the session endpoint set.
module ApiRequests
  def origin = Rails.configuration.x.public_origin

  def api_post(path, body = {}, headers: {})
    post path, params: body.to_json,
               headers: { "Content-Type" => "application/json", "Origin" => origin }.merge(headers)
  end

  def json = JSON.parse(response.body)

  # The token in the visitor cookie the app set, read as the app reads it.
  def cookie_token
    value = cookies[WebSession::COOKIE.to_s] or return
    env = Rails.application.env_config.merge("HTTP_COOKIE" => "#{WebSession::COOKIE}=#{value}")
    ActionDispatch::Request.new(env).cookie_jar.signed[WebSession::COOKIE]
  end

  # The visitor the cookie names, by the hash of its token.
  def cookie_visitor
    token = cookie_token
    token && Visitor.find_by(channel: "web", identity_hash: WebSession.identity_hash(token))
  end

  def start_session(language: nil)
    api_post "/api/session", language ? { language: } : {}
    expect(response).to have_http_status(:created)
    cookie_visitor
  end
end

RSpec.configure { |config| config.include ApiRequests, type: :request }
