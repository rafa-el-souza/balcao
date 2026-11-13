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

  # Review finding C1 of pull request #23: Solid Cable's own TrimJob deletes
  # 100 copies a run, and a conversation of ten turns writes about a hundred
  # and fifty, so after its /apagar on a quiet demo they outlived the 10
  # minutes by runs of 5. The task is run as Solid Queue runs it, against the
  # cable's table, made in the example's transaction (the test database has
  # only the primary's tables, and in test Solid Cable writes there).
  it "removes in one run every copy past its 5 minutes, however many there are" do
    ActiveRecord::Migration.suppress_messages { load Rails.root.join("db/cable_schema.rb") }
    SolidCable::Message.reset_column_information
    allow(SolidCable).to receive(:message_retention).and_return(5.minutes)
    copy = ->(at) { { channel: "trace:x", payload: "{}", channel_hash: 1, created_at: at } }
    SolidCable::Message.insert_all(Array.new(250) { copy.(6.minutes.ago) } + Array.new(10) { copy.(1.minute.ago) })

    task = YAML.safe_load(ERB.new(Rails.root.join("config/recurring.yml").read).result, aliases: true)
               .fetch("production").fetch("trim_solid_cable_messages")
    if task["command"]
      SolidQueue::RecurringJob.perform_now(task["command"])
    else
      task.fetch("class").constantize.perform_now(*Array(task["args"]))
    end

    expect(SolidCable::Message.where(created_at: ...5.minutes.ago).count).to eq 0
    expect(SolidCable::Message.count).to eq 10
  end

  # The test database has no Solid Queue tables, so the task is read as
  # Solid Queue's own checks read it (SolidQueue::RecurringTask's validations).
  it "runs that every 5 minutes, in the job container, whatever the writes" do
    tasks = YAML.safe_load(ERB.new(Rails.root.join("config/recurring.yml").read).result, aliases: true).fetch("production")
    task = tasks.fetch("trim_solid_cable_messages")
    schedule = Fugit.parse(task.fetch("schedule"), multi: :fail)

    expect(task.fetch("command")).to include("SolidCable::Message.trimmable")
    expect(schedule).to be_an_instance_of(Fugit::Cron)
    expect(schedule.rough_frequency).to eq 5.minutes
  end
end
