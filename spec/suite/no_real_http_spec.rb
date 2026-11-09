require "rails_helper"

RSpec.describe "SR-29 the suite makes no real HTTP request" do
  it "refuses a request to the model API" do
    expect { Net::HTTP.get(URI("https://api.anthropic.com/v1/models")) }
      .to raise_error(WebMock::NetConnectNotAllowedError)
  end

  it "refuses a request to localhost too" do
    expect { Net::HTTP.get(URI("http://localhost:3000/up")) }
      .to raise_error(WebMock::NetConnectNotAllowedError)
  end
end
