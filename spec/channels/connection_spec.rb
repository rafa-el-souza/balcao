require "rails_helper"

# FR-18, SR-03: the cable reads the same visitor cookie as the API. A page
# without one may still follow a trace (FR-12), so the connection is open to
# it, with no visitor.
RSpec.describe ApplicationCable::Connection, "FR-18 SR-03 the cable connection reads the visitor cookie", type: :channel do
  it "identifies the visitor by the hash of the token in the signed cookie, and the source address" do
    token = SecureRandom.base58(24)
    cookies.signed[WebSession::COOKIE] = token

    connect "/cable", env: { "REMOTE_ADDR" => "203.0.113.7" }

    expect(connection.identity_hash).to eq WebSession.identity_hash(token)
    expect(connection.source).to eq "203.0.113.7"
  end

  it "connects without a visitor when there is no cookie, or one whose signature does not verify" do
    cookies[WebSession::COOKIE] = "forged"

    connect "/cable"

    expect(connection.identity_hash).to be_nil
  end

  it "accepts the public origin only (SR-03)" do
    expect(Rails.application.config.action_cable.allowed_request_origins).to eq [ Rails.configuration.x.public_origin ]
  end
end
