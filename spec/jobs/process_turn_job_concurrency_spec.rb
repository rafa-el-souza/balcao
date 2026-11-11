require "rails_helper"

# The one real two-thread spec of NFR-02: no unique index keeps two turns of
# one conversation from running at once, the advisory lock does. It runs
# outside the transactional fixtures (review finding V4 of pull request #1):
# each thread needs a connection of its own and must see what the other
# committed, so the spec deletes its rows itself.
RSpec.describe "NFR-02 design §6.3 the per-conversation lock of ProcessTurnJob, in two threads" do
  include ModelResponses

  self.use_transactional_tests = false

  # A model whose first answer waits until the example lets it go.
  let(:model_class) do
    Class.new(FakeModel) do
      attr_reader :arrived, :release, :calls

      def initialize(...)
        super
        @arrived = Queue.new
        @release = Queue.new
        @calls = 0
        @mutex = Mutex.new
      end

      def call(request, nxt)
        first = @mutex.synchronize { (@calls += 1) == 1 }
        if first
          @arrived << true
          @release.pop(timeout: 10)
        end
        super
      end
    end
  end
  let(:fake) { model_class.new([ reply("[pt] Olá! Em que posso ajudar?"), reply("[pt] Temos, sim.") ]) }
  let(:visitor) { Visitor.identify!(channel: "web", identity_hash: SecureRandom.hex(32)) }
  let(:conversation) { Conversation.current_for!(visitor) }

  before { allow(AgentRunner).to receive(:default_client) { fake.client } }

  after { Visitor.where(id: visitor.id).delete_all }

  def turn(text) = Turn.for_inbound!(Message.record_inbound!(conversation:, external_id: SecureRandom.uuid, body: text))

  def waiting_for_a_lock = ApplicationRecord.connection.select_value("SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND NOT granted")

  def wait_until(seconds = 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    sleep 0.01 until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    yield
  end

  it "runs the conversation's second turn only after the first has replied, and its model call reads that reply" do
    first = turn("oi")
    second = turn("tem dipirona?")

    running = Thread.new { ProcessTurnJob.perform_now(first.id) }
    expect(fake.arrived.pop(timeout: 5)).to be(true)
    waiting = Thread.new { ProcessTurnJob.perform_now(second.id) }

    expect(wait_until { waiting_for_a_lock == 1 }).to be(true)
    expect(fake.calls).to eq(1)
    expect(second.reload.state).to eq("received")

    fake.release << true
    [ running, waiting ].each { |thread| thread.join(10) && thread.value }

    expect([ first.reload.state, second.reload.state ]).to eq(%w[replied replied])
    expect(first.outbound_message.created_at).to be < second.outbound_message.created_at
    expect(fake.requests.last.body[:messages].last(2)).to match([
      { role: "assistant", content: [ { type: "text", text: "Olá! Em que posso ajudar?" } ] },
      a_hash_including(role: "user")
    ])
    expect(waiting_for_a_lock).to eq(0)
  end

  # Review finding R1 of pull request #11: a turn a reset moved runs under the
  # lock of the conversation it moved to, never under the old one's.
  describe "a turn a reset moved into the conversation it opened" do
    let(:fake) { model_class.new([ reply("[pt] Olá!"), reply("[pt] Temos, sim."), reply("[pt] Olá de novo!") ]) }

    it "runs once, and a later turn of that conversation waits for it (FR-04, NFR-02)" do
      turn("/reiniciar")
      moved = turn("oi")
      running = Thread.new { ProcessTurnJob.perform_now(moved.id) }
      expect(fake.arrived.pop(timeout: 5)).to be(true)
      later = Turn.for_inbound!(Message.record_inbound!(conversation: Conversation.current_for!(visitor),
                                                        external_id: SecureRandom.uuid, body: "tem dipirona?"))
      waiting = Thread.new { ProcessTurnJob.perform_now(later.id) }

      wait_until { fake.calls >= 3 || waiting_for_a_lock == 1 }
      fake.release << true
      [ running, waiting ].each { |thread| thread.join(10) && thread.value }

      expect(fake.calls).to eq(2)
      expect(TraceEvent.where(turn_id: moved.id, name: "balcao.turn").count).to eq(1)
      expect(moved.reload.outbound_message.created_at).to be < later.reload.outbound_message.created_at
    end
  end
end
