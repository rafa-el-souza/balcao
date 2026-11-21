require "rails_helper"

# The attempts of a model call inside the turn's edge (threat model SR-20;
# design §10, M3-4).
RSpec.describe "SR-20 FR-14 a model call's attempts" do
  # A timeout as the SDK's requester raises one, with the library's own as
  # its cause.
  def timeout_caused_by(cause)
    raise cause
  rescue Exception # rubocop:disable Lint/RescueException
    begin
      raise Anthropic::Errors::APITimeoutError.new(url: nil)
    rescue Anthropic::Errors::APITimeoutError => e
      e
    end
  end

  # Review finding F2 of pull request #65 (and F6's third part): only an
  # attempt whose request reached the provider and whose answer then never
  # came is billed; one that never got a connection from the pool, never
  # opened one, or never finished writing its request reached nothing the
  # provider runs.
  describe "an attempt the edge abandoned" do
    it "is one whose answer timed out once the request was sent" do
      expect(ModelAttempts.abandoned?(timeout_caused_by(Net::ReadTimeout.new))).to be true
    end

    it "is not one that never finished writing its request, never opened its connection or never got one from the pool" do
      [ Net::WriteTimeout.new, Net::OpenTimeout.new, ConnectionPool::TimeoutError.new ].each do |cause|
        expect(ModelAttempts.abandoned?(timeout_caused_by(cause))).to be(false), cause.class.name
      end
    end
  end
end
