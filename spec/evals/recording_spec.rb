require "rails_helper"
require Rails.root.join("lib/evals/cli").to_s

# The recorded fast subset (evals/README.md, Running; design NFR-08): bin/evals
# --record --fast keeps each fast case's model calls, FR-20's check's among
# them, and its rubric's verdict; bin/evals --recorded replays them with no
# key, and fails a recording that no longer speaks for what the model reads.
# The suite records against the fake model, as the network, and never
# reaches the API (threat model SR-29).
RSpec.describe "NFR-08 SR-29 the recorded fast subset" do
  include ModelResponses

  let(:dir) { Pathname(Dir.mktmpdir("recordings")) }
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:git) { ->(*args) { args.first == "status" ? "" : "5594ff9\n" } }
  # What the API answers the turns and the checks of a recording run, and
  # the judge's answers apart.
  let(:network) { FakeModel.new(api) }
  let(:api) { [] }
  let(:judging) { FakeModel.new(judge_answers) }
  let(:judge_answers) { [] }
  let(:greeting) { Evals::CaseSet.load.find("greeting-pt-01") }
  let(:hours) { Evals::CaseSet.load.find("store-hours-pt-01") }

  # FR-20's check asks the client every turn uses, as in production, not the
  # suite's own fake (spec/support/guardrail.rb).
  before do
    allow(Guardrail).to receive(:default_client).and_call_original
    allow(ActiveRecord::Migration).to receive(:maintain_test_schema!)
  end

  after { FileUtils.remove_entry(dir) }

  def evals(*argv, env: { "ANTHROPIC_API_KEY" => "a-key" })
    recording_client = ->(recorder) { FakeModel::Client.new(network, api_key: "fake-model", max_retries: AgentRunner::MAX_RETRIES,
                                                                   initial_retry_delay: 0, middleware: [ recorder ]) }
    AgentRunner.with_client(judging.client) do
      Evals::CLI.new(argv, out:, err:, env:, results_dir: dir.join("results"), recordings_dir: dir.join("recordings"),
                           recording_client:, git:, pause: ->(_) { }).run
    end
  end

  def replay(*argv) = evals("--recorded", *argv, env: {})

  def verdict(pass) = message(content: [ text(JSON.generate(reason: pass ? "Meets the rubric." : "Misses it.", pass:)) ], model: "claude-haiku-5-5")

  def check = GuardrailVerdicts.verdict(false)

  def greeting_reply = reply("[pt] Olá! Aqui é a Farmácia Vida Longa. Posso ajudar com produtos, preços, reservas, horários e entregas.")

  def recording(kase) = JSON.parse(dir.join("recordings/#{kase.id}.json").read)

  describe "--record" do
    let(:api) { [ greeting_reply, check ] }
    let(:judge_answers) { [ *Evals::Judge.known_bad.map { verdict(false) }, verdict(true) ] }

    it "keeps the attempt's model calls in order, the check's among them, with what they speak for and the verdict" do
      expect(evals("--record", "--case", greeting.id)).to eq(0), err.string

      kept = recording(greeting)
      expect(kept["responses"]).to eq(JSON.parse(JSON.generate(api)))
      expect(kept["digests"]).to eq(Evals::Recording.digests(greeting))
      expect(kept["route"]).to eq("model" => "claude-opus-5-5", "effort" => "low")
      expect(kept["commit"]).to eq("5594ff9")
      expect(kept["verdict"]).to include("pass" => true, "reason" => "Meets the rubric.", "model" => "claude-haiku-5-5")
      expect(out.string).to include("recorded: ")
      # The judge's calls went to its own client, never into the recording.
      expect(judging.left).to eq(0)
      expect(network.left).to eq(0)
    end

    it "writes nothing for a case whose attempts all failed, and fails the run" do
      api.replace([ reply("[pt] Oi."), check, reply("[pt] Oi."), check, reply("[pt] Oi."), check ])

      expect(evals("--record", "--case", greeting.id)).to eq(1)
      expect(dir.join("recordings/#{greeting.id}.json")).not_to exist
      expect(err.string).to include("not recorded: #{greeting.id}")
    end

    it "takes the fast subset's cases alone, on the normal model, one attempt a case" do
      expect(evals("--record", "--case", "greeting-en-01")).to eq(2)
      expect(err.string).to include("fast subset alone")
      expect(evals("--record", "--all")).to eq(2)
      expect(evals("--record", "--fast", "--model", "economy")).to eq(2)
      expect(evals("--record", "--fast", "--repeat", "3")).to eq(2)
      expect(evals("--record")).to eq(2)
      expect(evals("--record", "--recorded", "--fast")).to eq(2)
      expect(network.requests).to be_empty
    end

    it "needs the key, as any live run" do
      expect(evals("--record", "--fast", env: {})).to eq(2)
      expect(err.string).to include("ANTHROPIC_API_KEY")
    end
  end

  describe "--recorded" do
    let(:api) { [ greeting_reply, check ] }
    let(:judge_answers) { [ *Evals::Judge.known_bad.map { verdict(false) }, verdict(true) ] }

    before do
      expect(evals("--record", "--case", greeting.id)).to eq(0), err.string
      out.truncate(0)
      out.rewind
    end

    it "replays the recording with no key and no judge, and passes" do
      expect(replay("--case", greeting.id)).to eq(0), out.string
      expect(out.string).to include("greeting-pt-01", "pass", "1 of 1 recorded case passed")
    end

    it "fails a recording made for another system prompt, naming what changed" do
      allow(PromptDigest).to receive(:prompt).and_return("0000000000000000")

      expect(replay("--case", greeting.id)).to eq(1)
      expect(out.string).to include("FAIL", "stale: prompt changed since the recording", "bin/evals --record --fast")
    end

    it "fails a recording made for another case's messages" do
      changed = greeting.with(messages: [ "olá" ])
      allow_any_instance_of(Evals::CaseSet).to receive(:find).and_call_original
      allow_any_instance_of(Evals::CaseSet).to receive(:find).with(greeting.id).and_return(changed)

      expect(replay("--case", greeting.id)).to eq(1)
      expect(out.string).to include("stale: case changed")
    end

    # The tools' results carry the catalogue's names, prices and stock,
    # which the model read when it answered.
    it "fails a recording made for another catalogue" do
      entries = CatalogueSeed.entries
      changed = entries.map { |entry| entry[:sku] == "dipirona-500mg-10cp" ? entry.merge(price: BigDecimal("8.90")) : entry }
      expect(changed).not_to eq(entries)
      allow(CatalogueSeed).to receive(:entries).and_call_original
      allow(CatalogueSeed).to receive(:entries).with(no_args).and_return(changed)
      allow(CatalogueSeed).to receive(:entries).with(overlay: nil).and_return(changed)

      expect(replay("--case", greeting.id)).to eq(1)
      expect(out.string).to include("stale: case changed")
    end

    it "fails when the run asks for fewer answers than the recording holds" do
      path = dir.join("recordings/#{greeting.id}.json")
      data = JSON.parse(path.read)
      data["responses"] << data["responses"].last
      path.write(JSON.generate(data))

      expect(replay("--case", greeting.id)).to eq(1)
      expect(out.string).to include("1 of the recording's 3 answers were never asked for")
    end

    it "fails when the run asks for more answers than the recording holds" do
      path = dir.join("recordings/#{greeting.id}.json")
      data = JSON.parse(path.read)
      data["responses"].pop
      path.write(JSON.generate(data))

      expect(replay("--case", greeting.id)).to eq(1)
      expect(out.string).to include("FAIL")
    end

    it "fails when the judge would read another reply than the recorded verdict did" do
      path = dir.join("recordings/#{greeting.id}.json")
      data = JSON.parse(path.read)
      data["verdict"]["reads"] = "0" * 64
      path.write(JSON.generate(data))

      expect(replay("--case", greeting.id)).to eq(1)
      expect(out.string).to include("the judge would read another reply or rubric than the recording's verdict did")
    end

    it "fails a recorded verdict that failed" do
      path = dir.join("recordings/#{greeting.id}.json")
      data = JSON.parse(path.read)
      data["verdict"]["pass"] = false
      path.write(JSON.generate(data))

      expect(replay("--case", greeting.id)).to eq(1)
    end

    it "fails a fast case with no recording and a recording of no fast case" do
      dir.join("recordings/not-a-case.json").write("{}")

      expect(replay).to eq(1)
      expect(out.string).to include("no recording at", "store-hours-pt-01")
      expect(out.string).to include("not-a-case: evals/recordings/not-a-case.json records no case of the fast subset")
    end

    it "takes no other selection than --case" do
      expect(replay("--all")).to eq(2)
      expect(replay("--fast")).to eq(2)
      expect(replay("--case", "greeting-en-01")).to eq(2)
    end

    it "replays at the recording's time" do
      seen = nil
      allow(Evals::Recording::Replayed).to receive(:new).and_wrap_original do |original, *args|
        seen = Time.current
        original.call(*args)
      end
      recorded_at = Time.iso8601(recording(greeting).fetch("recorded_at"))

      travel_to(recorded_at + 30.days) { replay("--case", greeting.id) }

      expect(Time.current).not_to eq(recorded_at)
      expect(out.string).to include("1 of 1 recorded case passed")
      expect(seen).to be_within(31.days).of(recorded_at)
    end
  end

  # A tool call names a product by its id, which the catalogue's seed draws
  # anew in every attempt: the recording keeps each id it saw with the
  # product's sku, and the replay hands the model's call the id the same
  # product has then.
  describe "a reservation on the recording's catalogue" do
    let(:reservation) { Evals::CaseSet.load.find("reservation-ok-pt-01") }
    # The API as the recording met it: an answer that names a product is
    # written when its request comes, from the attempt's own catalogue.
    let(:network) do
      Class.new(FakeModel) do
        def initialize(script)
          super([])
          @script = script
        end

        def left = @script.size

        def call(request, nxt)
          answer = @script.shift
          @responses = [ (answer.respond_to?(:call) ? answer.call : answer).to_h.deep_symbolize_keys ] if answer
          super
        end
      end.new(api)
    end
    let(:dipirona) { -> { Product.find_by!(sku: "dipirona-500mg-10cp").id } }
    let(:api) do
      [ tool_turn(tool_use("search_products", { query: "dipirona" })), reply("[pt] Temos Dipirona 500 mg, 10 comprimidos, por R$ 7,90."), check,
        tool_turn(tool_use("search_products", { query: "dipirona comprimido" })),
        -> { tool_turn(tool_use("create_reservation", { product_id: dipirona.call, quantity: 2 })) },
        reply("[pt] Pronto, reservei duas caixas. O código está abaixo."), check ]
    end

    it "is made again on the product's id of the replay" do
      expect(evals("--record", "--case", reservation.id)).to eq(0), out.string + err.string
      expect(recording(reservation)["products"].values).to eq([ "dipirona-500mg-10cp" ])

      expect(replay("--case", reservation.id)).to eq(0), out.string
      expect(out.string).to include("1 of 1 recorded case passed")
    end
  end

  describe Evals::Recording::Recorder do
    it "keeps a 529's status, body and retry headers, and a timeout as the fake replays it" do
      overloaded = error(:overloaded).merge(headers: { "retry-after" => "1" })
      network = FakeModel.new([ overloaded, { timeout: true }, { timeout: "open" }, reply("[pt] Oi.") ])
      recorder = described_class.new
      client = FakeModel::Client.new(network, api_key: "fake-model", max_retries: 0, initial_retry_delay: 0, middleware: [ recorder ])
      call = -> { client.messages.create(model: "claude-opus-5-5", max_tokens: 10, messages: [ { role: "user", content: "oi" } ]) }

      expect { call.() }.to raise_error(Anthropic::Errors::InternalServerError)
      expect { call.() }.to raise_error(Anthropic::Errors::APITimeoutError)
      expect { call.() }.to raise_error(Anthropic::Errors::APITimeoutError)
      expect(call.().content.last.text).to eq("[pt] Oi.")

      expect(recorder.responses.map { |response| response.except("body") }).to eq(
        [ { "status" => 529, "headers" => { "retry-after" => "1" } }, { "timeout" => true }, { "timeout" => "open" }, { "status" => 200 } ]
      )
      expect(recorder.responses.first["body"]).to eq(JSON.parse(JSON.generate(overloaded[:body])))
      expect(FakeModel.new(recorder.responses).left).to eq(4)
      expect(recorder.broken).to be_nil
    end
  end
end
