require "rails_helper"
require "fugit"

# FR-17: every ten minutes the canary asks the attendant a visitor's question
# on a reserved conversation of a fixed system visitor, through a visitor's
# turn (the budget's gate, AgentRunner, FR-20's check, the stored reply) with
# no transport, always on the economy model (ADR-0003); it passes when the
# reply comes within 20 seconds and holds the marker its question elicits, or,
# when the demo is paused, when the reply is a pause's fixed text ("pipeline
# alive", not "model answered"). Each run counts as passed or failed on the
# day (FR-13's pipeline uptime, NFR-04) and tells the external monitor; it
# keeps only the conversation and the count, and its calls count toward the
# month's spend.
RSpec.describe "FR-17 NFR-04 the canary" do
  include ModelResponses
  include ActiveJob::TestHelper

  let(:monitor) { "https://monitor.example/api/v1/heartbeat/canary-token-of-the-specs" }
  let(:answer) { "[pt] Olá! A Farmácia Copaíba fica na Rua dos Boticários, 120 — Floresta, em Belo Horizonte." }
  let(:responses) { [ reply(answer, model: "claude-haiku-5-5") ] }
  let(:fake) { FakeModel.new(responses) }
  let!(:beat) { stub_request(:post, monitor).to_return(status: 200) }
  let!(:failure) { stub_request(:post, "#{monitor}/fail").to_return(status: 200) }

  around do |example|
    saved = [ Rails.configuration.x.budget_cap_usd, Rails.configuration.x.monitor_url ]
    Rails.configuration.x.budget_cap_usd = BigDecimal("10")
    Rails.configuration.x.monitor_url = monitor
    example.run
  ensure
    Rails.configuration.x.budget_cap_usd, Rails.configuration.x.monitor_url = saved
  end

  before do
    allow(AgentRunner).to receive(:default_client) { fake.client }
    allow(Rails.logger).to receive(:info).and_call_original
    allow(Rails.logger).to receive(:error).and_call_original
  end

  # The canary's turn runs in the visitors' own job, ProcessTurnJob, called
  # in the canary's job; a turn that breaks is left to the job's next
  # attempt, enqueued as a visitor's is.
  def run(**) = Canary.new.run(**)

  def counts = DailyAggregate.where(kind: "canary").to_h { |row| [ row.key, row.count ] }

  def month = BudgetState.for_month!

  def kept(conversation) = [ conversation.messages.count, conversation.turns.count, TraceEvent.count, UsageRecord.count ]

  describe "a run that passes" do
    it "asks on the economy model in normal mode, finds the marker, counts a pass and tells the monitor all is well" do
      result = run

      expect(result).to have_attributes(passed: true, mode: "economy")
      expect(fake.requests.first.body).to include(model: "claude-haiku-5-5")
      expect(fake.requests.first.body.fetch(:messages).last.fetch(:content).to_s).to include(Canary::QUESTION)
      expect(counts).to eq("passed" => 1)
      expect(beat).to have_been_requested.once
      expect(failure).not_to have_been_requested
      expect(Rails.logger).to have_received(:info).with(/\Acanary: passed in \d+ ms \(mode economy\)\z/)
    end

    it "elicits the street of the store's address, read from the store sheet" do
      expect(Canary.marker).to eq("Rua dos Boticários")
    end

    # V4 of #64's review: a reply that abbreviates the street's kind, writes
    # it in lower case, without its accents or decomposed, still holds it.
    [ "Fica na R. dos Boticários, 120.", "fica na rua dos boticarios, 120", "Fica na Rua dos Boticários, 120".unicode_normalize(:nfd),
      "Estamos na Av. dos  Boticários, 120" ].each do |text|
      it "finds the street in #{text.inspect}" do
        responses.replace([ reply("[pt] #{text}", model: "claude-haiku-5-5") ])

        expect(run).to have_attributes(passed: true)
      end
    end

    it "keeps only its conversation, its visitor and the day's count; its calls stay in the month's spend" do
      run

      visitor = Visitor.find_by!(channel: "system")
      conversation = Conversation.find_by!(visitor:)
      expect(kept(conversation)).to eq([ 0, 0, 0, 0 ])
      expect(month.spent_usd).to be_positive
    end

    it "runs on the economy model in the month's economy too, the gate open" do
      Rails.configuration.x.economy_allowed = true
      month.update!(spent_usd: BigDecimal("7"))

      expect(run).to have_attributes(passed: true, mode: "economy")
      expect(fake.requests.first.body).to include(model: "claude-haiku-5-5")
    end

    it "broadcasts nothing: no page follows the system visitor's conversation" do
      allow(ActionCable.server).to receive(:broadcast)

      run

      expect(ActionCable.server).not_to have_received(:broadcast)
    end

    it "makes one system visitor and one conversation, which the next runs find again" do
      responses.push(reply(answer, model: "claude-haiku-5-5"))

      2.times { run }

      expect(Visitor.where(channel: "system").count).to eq(1)
      expect(Conversation.joins(:visitor).where(visitors: { channel: "system" }).count).to eq(1)
      expect(counts).to eq("passed" => 2)
    end

    it "is the same system visitor however many callers ask at once (NFR-02)" do
      first = Visitor.canary!

      expect(Visitor.canary!).to eq(first)
      expect(first).to have_attributes(channel: "system", identity_hash: Visitor::CANARY)
    end
  end

  # R4 of #64's fix review: a street whose name after its kind is a letter
  # or a number would be found in any text, the fallback's among them.
  it "never takes the fallback's text for a street named by one letter or a number" do
    [ "Rua A", "Rua 7" ].each do |street|
      allow(Canary).to receive(:marker).and_return(street)

      expect(Canary.marked?(FixedReply.fallback("pt-BR"))).to be(false)
      expect(Canary.marked?("Fica na #{street}, 10.")).to be(true)
    end
  end

  describe "paused, it passes on a pause's fixed text, with no model call" do
    let(:responses) { [] }

    it "at the month's cap" do
      month.update!(spent_usd: BigDecimal("10"))

      expect(run).to have_attributes(passed: true, mode: "paused")
      expect(fake.requests).to be_empty
      expect(beat).to have_been_requested.once
    end

    it "at the day's slice while ADR-0003's gate keeps the economy closed" do
      month.update!(day: Date.current, day_spent_usd: BigDecimal("0.5"))

      expect(run).to have_attributes(passed: true, mode: "paused")
      expect(fake.requests).to be_empty
    end

    it "when the operator forced the pause" do
      Budget.force!("paused")

      expect(run).to have_attributes(passed: true, mode: "paused")
      expect(fake.requests).to be_empty
    end
  end

  describe "a run that fails" do
    it "fails when the reply lacks the marker, counts a failure and tells the monitor why, keeping nothing" do
      responses.replace([ reply("[pt] Olá! Em que posso ajudar?", model: "claude-haiku-5-5") ])

      result = run

      expect(result).to have_attributes(passed: false, reason: "the reply lacks the marker (outcome replied)")
      expect(counts).to eq("failed" => 1)
      expect(failure.with(body: "canary: the reply lacks the marker (outcome replied)")).to have_been_requested.once
      expect(beat).not_to have_been_requested
      expect(kept(Conversation.sole)).to eq([ 0, 0, 0, 0 ])
      expect(Rails.logger).to have_received(:error).with("canary: failed: the reply lacks the marker (outcome replied)")
    end

    it "fails when the model cannot answer, naming the turn's outcome and the error's class" do
      responses.replace(Array.new(3) { { status: 529, body: { type: "error", error: { type: "overloaded_error", message: "Overloaded" } } } })

      expect(run).to have_attributes(passed: false, reason: "the reply lacks the marker (outcome model_error, Anthropic::Errors::OverloadedError)")
      expect(counts).to eq("failed" => 1)
    end

    # H2 of #64's review: the run deletes its spans, the only place the
    # error's class was, so the reason carries it (a class, SR-30).
    it "names the error's class of a model that is gone, which no other line keeps" do
      responses.replace([ { status: 404, body: { type: "error", error: { type: "not_found_error", message: "model: claude-haiku-5-5" } } } ])

      expect(run).to have_attributes(passed: false, reason: "the reply lacks the marker (outcome model_error, Anthropic::Errors::NotFoundError)")
      expect(failure.with(body: "canary: the reply lacks the marker (outcome model_error, Anthropic::Errors::NotFoundError)"))
        .to have_been_requested.once
    end

    it "fails when the reply took longer than 20 seconds" do
      allow(TurnProcessor).to receive(:new).and_wrap_original do |original, *args, **kwargs|
        travel(21.seconds)
        original.call(*args, **kwargs)
      end

      expect(run).to have_attributes(passed: false, reason: a_string_matching(/\Athe reply took 2\d{4} ms from the run's time, over 20000\z/))
    end

    # H6 of #64's review: a visitor's 20 seconds start when the message
    # arrives, before the queue; so do the canary's, when its job was due.
    # SR-20's hard edge (M3-4): the canary's turn has FR-17's twenty seconds,
    # not a visitor's sixty, so a slow model ends it at the canary's own time
    # and frees the worker's thread then.
    it "gives its turn's model only the canary's twenty seconds" do
      run

      expect(fake.requests.first.options[:timeout]).to be_between(Canary::WITHIN.to_f - 1, Canary::WITHIN.to_f)
    end

    it "fails when its own job started more than 20 seconds after its time, a queue the visitors' turns hold" do
      freeze_time
      CanaryJob.perform_later
      travel(30.seconds)

      perform_enqueued_jobs(only: CanaryJob)

      expect(counts).to eq("failed" => 1)
      expect(failure.with(body: "canary: the run started 30 s after its time, over 20 s")).to have_been_requested.once
      expect(fake.requests).to be_empty
    end

    it "counts the 20 seconds from its job's time, the queue's wait included" do
      allow(TurnProcessor).to receive(:new).and_wrap_original do |original, *args, **kwargs|
        travel(6.seconds)
        original.call(*args, **kwargs)
      end

      result = run(due_at: 15.seconds.ago)

      expect(result).to have_attributes(passed: false, reason: a_string_matching(/\Athe reply took 2\d{4} ms from the run's time, over 20000\z/))
    end

    it "fails when the turn breaks, leaving it to its job's next attempt as a visitor's, and keeps nothing of it" do
      allow(Guardrail).to receive(:new).and_raise(ActiveRecord::ConnectionFailed, "words of no one")

      result = run

      expect(result).to have_attributes(passed: false, reason: "no reply, the turn is failed (ActiveRecord::ConnectionFailed)")
      expect(failure.with(body: "canary: no reply, the turn is failed (ActiveRecord::ConnectionFailed)")).to have_been_requested.once
      expect(enqueued_jobs.map { |job| job[:job] }).to include(ProcessTurnJob)
      expect(kept(Conversation.sole)).to eq([ 0, 0, 0, 0 ])
    end

    # C1 of #64's review: the canary's turn takes a visitor's way, its job
    # and the conversation's lock, so a fault there fails it too.
    it "fails when a visitor's turn cannot run through its job, as when the conversation's lock breaks" do
      allow(ConversationLock).to receive(:hold).and_raise(ActiveRecord::StatementInvalid, "words of no one")

      expect(run).to have_attributes(passed: false, reason: "no reply, the turn is received (not run)")
      expect(fake.requests).to be_empty
    end

    it "fails when the run breaks before any turn, as when the system visitor cannot be read" do
      allow(Visitor).to receive(:canary!).and_raise(ActiveRecord::ConnectionFailed, "gone")

      expect(run).to have_attributes(passed: false, reason: "the run broke: ActiveRecord::ConnectionFailed")
      expect(fake.requests).to be_empty
    end

    # H8 of #64's review: the run keeps no trace, and its job no failed
    # execution, so the line says where, by the app's frames, as the nightly
    # job's does; the monitor's text keeps the class alone.
    it "logs where the run broke by the app's frames, never the error's message" do
      allow(Visitor).to receive(:canary!).and_raise(NoMethodError, "words of no one")

      run

      expect(Rails.logger).to have_received(:error).with(%r{\Acanary: the run broke: NoMethodError\n.*app/models/canary\.rb:\d+}m)
      expect(Rails.logger).not_to have_received(:error).with(/words of no one/)
      expect(failure.with(body: "canary: the run broke: NoMethodError")).to have_been_requested.once
    end

    # AdvisoryLock.free?'s own spec holds the lock from another session
    # (spec/models/conversation_lock_spec.rb); here it is found held.
    it "fails at once, without waiting, while an earlier run's turn still holds the canary's conversation" do
      conversation = Conversation.current_for!(Visitor.canary!)
      allow(AdvisoryLock).to receive(:free?).and_call_original
      allow(AdvisoryLock).to receive(:free?).with("conversation:#{conversation.id}").and_return(false)

      expect(run).to have_attributes(passed: false, reason: "an earlier run's turn still holds the canary's conversation")
      expect(fake.requests).to be_empty
      expect(counts).to eq("failed" => 1)
      expect(failure.with(body: "canary: an earlier run's turn still holds the canary's conversation")).to have_been_requested.once
    end


    # H9 of #64's review: a count the database refused is lost from FR-13's
    # uptime, and the database's faults fail most runs too, so the monitor
    # hears a failure rather than all is well.
    it "tells the monitor a failure when the day's count cannot be written" do
      allow(DailyAggregate).to receive(:add!).and_raise(ActiveRecord::ConnectionFailed, "gone")

      expect(run).to have_attributes(passed: false, reason: "the day's count not written: ActiveRecord::ConnectionFailed")
      expect(failure.with(body: "canary: the day's count not written: ActiveRecord::ConnectionFailed")).to have_been_requested.once
      expect(beat).not_to have_been_requested
    end

    # H11 of #64's review: the rows' deletion after a verdict is the next
    # run's to finish when it breaks; it never replaces the verdict.
    it "keeps its verdict when the rows cannot be deleted after it, for the next run to clear" do
      deletes = 0
      allow(Message).to receive(:where).and_wrap_original do |original, *args, **kwargs|
        relation = original.call(*args, **kwargs)
        next relation unless kwargs.key?(:conversation_id) || args.first.is_a?(Hash) && args.first.key?(:conversation_id)

        deletes += 1
        allow(relation).to receive(:delete_all).and_raise(ActiveRecord::QueryCanceled, "slow") if deletes == 2
        relation
      end

      expect(run).to have_attributes(passed: true)
      expect(Rails.logger).to have_received(:error).with("canary: the run's rows not deleted, ActiveRecord::QueryCanceled; the next run clears them")
    end
  end

  # H1 of #64's review: the canary asks on the economy model, and the
  # visitors' normal mode runs on another route (its model, its fallback
  # beta), so a fault of that route alone shows only in the visitors' own
  # turns: their outcomes, never their words, fail the run.
  describe "the visitors' own turns" do
    let(:refused) { { status: 400, body: { type: "error", error: { type: "invalid_request_error", message: "words of no one" } } } }
    let(:person) { create(:conversation) }

    def visitor_turn(at: Time.current)
      turn = travel_to(at) { Turn.for_inbound!(Message.record_inbound!(conversation: person, external_id: SecureRandom.uuid, body: "tem dipirona?")) }
      ProcessTurnJob.perform_now(turn.id)
      turn.reload
    end

    it "fail the run when the last half hour's turns that called the model all failed at the model's API" do
      responses.replace([ refused, refused, reply(answer, model: "claude-haiku-5-5") ])
      2.times { visitor_turn }

      result = run

      expect(result).to have_attributes(passed: false, reason: "visitors' turns: 2 of 2 in the last 30 minutes failed at the model's API " \
                                                               "(outcome model_error, Anthropic::Errors::BadRequestError)")
      expect(counts).to eq("failed" => 1)
      expect(failure.with(body: "canary: #{result.reason}")).to have_been_requested.once
    end

    it "let the run pass when one of them was answered, or when only one called the model" do
      responses.replace([ refused, reply("[pt] Temos sim.", model: "claude-opus-5-5"), reply(answer, model: "claude-haiku-5-5"),
                          refused, reply(answer, model: "claude-haiku-5-5") ])
      2.times { visitor_turn }

      expect(run).to have_attributes(passed: true)

      Turn.where(conversation: person).delete_all
      visitor_turn

      expect(run).to have_attributes(passed: true)
    end

    # R1 of #64's fix review: a visitor's own question can end a turn in the
    # fallback (cut at the turn's output limit, its tool calls, its time), so
    # only a turn the model's API failed counts against the route.
    it "let the run pass when the visitors' own questions cut the model off, the route healthy" do
      cut = reply("[pt] Temos dipirona, paracetamol, ibuprofeno", model: "claude-opus-5-5", stop_reason: :max_tokens)
      responses.replace([ cut, cut, reply(answer, model: "claude-haiku-5-5") ])
      2.times { visitor_turn }

      expect(run).to have_attributes(passed: true)
    end

    it "leave out a turn older than half an hour and one that called no model" do
      responses.replace([ refused, refused, reply(answer, model: "claude-haiku-5-5") ])
      visitor_turn(at: 40.minutes.ago).update_columns(updated_at: 40.minutes.ago)
      visitor_turn
      Budget.force!("paused")
      visitor_turn
      Budget.force!(nil)

      expect(run).to have_attributes(passed: true)
    end
  end

  # R3 of #64's fix review: the reply is committed before the turn's root
  # span is finished with its outcome and the error's class, which the
  # verdict reads; the turn's job runs in the run's own thread, so the
  # verdict reads a turn its job finished.
  it "reads the turn's outcome only once its job finished it, however long the turn's end takes" do
    responses.replace(Array.new(3) { { status: 529, body: { type: "error", error: { type: "overloaded_error", message: "Overloaded" } } } })
    allow_any_instance_of(TurnProcessor).to receive(:broadcast_reply).and_wrap_original do |original, *args|
      travel(1.second)
      original.call(*args)
    end

    expect(run.reason).to eq("the reply lacks the marker (outcome model_error, Anthropic::Errors::OverloadedError)")
  end

  it "asks through a visitor's turn job, ProcessTurnJob, in its own thread, never the turn's processor alone" do
    allow(ProcessTurnJob).to receive(:perform_now).and_call_original
    allow(ProcessTurnJob).to receive(:perform_later)

    run

    expect(ProcessTurnJob).to have_received(:perform_now).once
    expect(ProcessTurnJob).not_to have_received(:perform_later)
  end

  it "clears what an earlier run left, so the model reads no history and the conversation never grows" do
    conversation = Conversation.current_for!(Visitor.canary!)
    left = Message.record_inbound!(conversation:, external_id: "canary-left", body: Canary::QUESTION, source: "canary")
    Turn.for_inbound!(left).update!(state: "running")

    expect(run).to have_attributes(passed: true)
    expect(fake.requests.first.body.fetch(:messages).size).to eq(1)
    expect(kept(conversation)).to eq([ 0, 0, 0, 0 ])
  end

  # A rehearsal host has no monitor (design §8): the canary runs and counts
  # all the same.
  it "runs and counts with no monitor URL, sending nothing" do
    Rails.configuration.x.monitor_url = nil

    expect(Canary.new.run).to have_attributes(passed: true)
    expect(counts).to eq("passed" => 1)
    expect(a_request(:any, /monitor\.example/)).not_to have_been_made
  end

  it "is scheduled every ten minutes in production, beside the Telegram watch (config/recurring.yml)" do
    schedule = YAML.safe_load(ERB.new(Rails.root.join("config/recurring.yml").read).result).fetch("production")

    expect(schedule.fetch("canary")).to eq("class" => "CanaryJob", "schedule" => "every 10 minutes")
    expect(schedule.fetch("telegram_watch")).to include("class" => "TelegramWatchJob")
    expect(Fugit.parse_cronish(schedule.dig("telegram_watch", "schedule")).rough_frequency).to eq(600)
  end

  it "runs in its job, which a failure never makes try again (the next run is ten minutes away) and still tells the monitor" do
    allow(Canary).to receive(:new).and_raise(ActiveRecord::ConnectionFailed, "gone")

    expect { CanaryJob.perform_now }.not_to raise_error
    expect(enqueued_jobs).to be_empty
    expect(failure.with(body: "canary: not run, ActiveRecord::ConnectionFailed")).to have_been_requested.once
    expect(Rails.logger).to have_received(:error).with(%r{\Acanary: not run, ActiveRecord::ConnectionFailed\n.*app/jobs/canary_job\.rb:\d+}m)
  end
end
