# The model without the network (design §6.4, threat model SR-29): it answers
# each request with the next of a list of responses, as the API would have sent
# them, and never calls the API. It sits where the network does, innermost in
# the SDK's middleware chain (the place the SDK's Bedrock and Vertex clients
# adapt requests), so every middleware above it, the client's and the
# request's, runs as it would in production. The SDK parses each answer into
# its own types, raises its own error classes for 429 and 529 and retries them
# as in production, so code behind the fake runs the production paths.
# Responses come from the SDK's types in the suite
# (spec/support/model_responses.rb) and, once bin/evals records them, from
# evals/recordings/<case>.json:
#
#   { "responses": [ { "status": 200, "body": { ...a Messages API response... } },
#                    { "status": 529, "body": { "type": "error", ... } },
#                    { "timeout": true } ] }
#
# A request beyond the list raises Unscripted, so an unexpected model call
# fails loudly instead of answering something nobody recorded.
class FakeModel
  include Anthropic::Middleware

  class Unscripted < StandardError; end

  # Every request the SDK sent, as Anthropic::APIRequest (body, headers, options).
  attr_reader :requests

  def self.load(path) = new(JSON.parse(File.read(path)).fetch("responses"))

  def initialize(responses)
    @responses = responses.map { |response| response.to_h.deep_symbolize_keys }
    @requests = []
  end

  # An SDK client whose every request this fake answers. No retry delay, so
  # the SDK's retries cost nothing in the suite.
  def client
    Client.new(self, api_key: "fake-model", max_retries: AgentRunner::MAX_RETRIES, initial_retry_delay: 0)
  end

  def call(request, _next)
    @requests << request
    response = @responses.shift or raise Unscripted, "the fake model has no response left for request #{@requests.size}"
    raise Anthropic::Errors::APITimeoutError.new(url: request.url) if response[:timeout]

    Anthropic::APIResponse.new(
      status: response.fetch(:status),
      headers: { "content-type" => "application/json" }.merge(response.fetch(:headers, {})),
      body: JSON.generate(response.fetch(:body)),
      request:
    )
  end

  # The SDK's client with the fake in place of the network: the SDK calls
  # provider_middleware for the innermost entry of every request's chain.
  class Client < Anthropic::Client
    def initialize(fake, **)
      @fake = fake
      super(**)
    end

    private

    def provider_middleware = @fake
  end
end
