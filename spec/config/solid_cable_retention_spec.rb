require "rails_helper"
require "yaml"
require "fugit"

# Solid Cable stores each broadcast as a row of the cable database, the copy
# its listeners read: the replies, the spans and the deletion's word of a
# conversation. It kept them a day, and trimmed only on writes, so a quiet
# demo kept them longer; a deletion (FR-05) never reached them. Production
# keeps them 5 minutes and trims every 5, so a copy outlives its broadcast by
# about 10 minutes at most, the exception SR-32 names (ADR-0015).
RSpec.describe "SR-32 the cable's copies of a conversation live minutes, not a day" do
  it "keeps a broadcast's copy 5 minutes in production" do
    options = Rails.application.config_for(:cable, env: "production").to_h.symbolize_keys

    expect(SolidCable::Configuration.new(**options).message_retention).to eq 5.minutes
    expect(options[:adapter]).to eq "solid_cable"
  end

  # The test database has no Solid Queue tables, so the task is read as
  # Solid Queue's own checks read it (SolidQueue::RecurringTask's validations).
  it "trims the copies past it every 5 minutes, in the job container, whatever the writes" do
    tasks = YAML.safe_load(ERB.new(Rails.root.join("config/recurring.yml").read).result, aliases: true).fetch("production")
    _, task = tasks.find { |_, options| options["class"] == "SolidCable::TrimJob" }
    schedule = Fugit.parse(task.fetch("schedule"), multi: :fail)

    expect(task["class"].safe_constantize).to be < ActiveJob::Base
    expect(schedule).to be_an_instance_of(Fugit::Cron)
    expect(schedule.rough_frequency).to eq 5.minutes
    expect(task.keys).to contain_exactly("class", "schedule")
  end
end
