require "rails_helper"

# FR-18, SR-03: the cable reads the same visitor cookie as the API. A page
# without one may still follow a trace (FR-12), so the connection is open to
# it, with no visitor.
RSpec.describe ApplicationCable::Connection, "FR-18 SR-03 the cable connection reads the visitor cookie", type: :channel do
  it "identifies the visitor by the hash of the token in the signed cookie, and the source address" do
    token = SecureRandom.base58(24)
    cookies.signed[WebSession::PLAIN_NAME] = token

    connect "/cable", env: { "REMOTE_ADDR" => "203.0.113.7" }

    expect(connection.identity_hash).to eq WebSession.identity_hash(token)
    expect(connection.source).to eq "203.0.113.7"
  end

  # Threat model R7, closed at M3-6: over HTTPS, as production always is, the
  # cable reads the __Host- cookie the API sets there, and never the bare
  # name, which another name under the domain could plant.
  it "reads the __Host- cookie over HTTPS, and not the bare name" do
    token = SecureRandom.base58(24)
    cookies.signed["__Host-balcao_visitor"] = token

    connect "/cable", env: { "HTTPS" => "on" }

    expect(connection.identity_hash).to eq WebSession.identity_hash(token)
  end

  it "takes no visitor from a cookie of the bare name over HTTPS, though its signature verifies" do
    cookies.signed[WebSession::PLAIN_NAME] = SecureRandom.base58(24)

    connect "/cable", env: { "HTTPS" => "on" }

    expect(connection.identity_hash).to be_nil
  end

  it "connects without a visitor when there is no cookie, or one whose signature does not verify" do
    cookies[WebSession::PLAIN_NAME] = "forged"

    connect "/cable"

    expect(connection.identity_hash).to be_nil
  end

  it "accepts the public origin only (SR-03)" do
    expect(Rails.application.config.action_cable.allowed_request_origins).to eq [ Rails.configuration.x.public_origin ]
  end
end
