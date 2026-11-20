require "rails_helper"

# Review finding C2 of pull request #53, its verifier's concurrent twin: two
# requests with one solved token at once each hear Cloudflare's yes, since
# its check of a spent token converges in seconds; the table's key lets one
# of them mint. It runs outside the transactional fixtures, each thread on a
# connection of its own, so it deletes its rows itself.
RSpec.describe "SR-39 a token mints once, two requests at once" do
  self.use_transactional_tests = false

  after { TurnstileRedemption.delete_all }

  it "lets one of two yeses for the same token through" do
    host = "balcao.example"
    answer = { "success" => true, "hostname" => host, "action" => "session", "error-codes" => [] }
    stub_request(:post, TurnstileStubs::SITEVERIFY).to_return do
      sleep 0.2
      { status: 200, body: answer.to_json }
    end
    check = Turnstile.new(secret: "0x4AAAAAAAreal-secret-for-the-specs", host:)
    gate = Queue.new

    threads = Array.new(2) do
      Thread.new do
        gate.pop
        ActiveRecord::Base.connection_pool.with_connection { check.passed?("0.one-solved-token") }
      end
    end
    2.times { gate << true }

    expect(threads.map(&:value).sort_by(&:to_s)).to eq [ false, true ]
    expect(TurnstileRedemption.count).to eq 1
  end
end
