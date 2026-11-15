require "rails_helper"

# A job waits for the worker's next look at the queue before it runs, and a
# turn has one such wait on the web and one on Telegram (the update's job;
# the turn's job, which the update's job enqueues, is claimed at the latest
# when that job ends, since a worker looks again whenever one of its threads
# frees up). Solid Queue's generator wrote a look a
# second for the workers, so a turn waited half a second on average (design
# §10, the notes of 2026-11-15); the gem's own default for a worker is a tenth
# of a second, for an indexed query on a queue that is empty most of the time
# (slice M4-2).
RSpec.describe "NFR-01 the queue's workers look for jobs every tenth of a second" do
  it "has every worker of every environment poll at 0.1 s, as Solid Queue reads config/queue.yml" do
    config = ActiveSupport::ConfigurationFile.parse(Rails.root.join("config/queue.yml")).deep_symbolize_keys

    expect(config.keys).to contain_exactly(:default, :development, :test, :production)
    config.each_value do |environment|
      expect(environment[:workers].map { |worker| worker[:polling_interval] }).to eq([ 0.1 ])
    end
  end
end
