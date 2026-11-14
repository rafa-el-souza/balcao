require "rails_helper"
require "open3"
require Rails.root.join("lib/evals/cli").to_s

# bin/evals (evals/README.md, Running): the MVP's live run on the normal
# model, its results file and the scorecard it rewrites. The suite runs it on
# the fake model; only a person's run reaches the API (threat model SR-29).
RSpec.describe "NFR-08 SR-18 SR-29 bin/evals" do
  include ModelResponses

  let(:dir) { Pathname(Dir.mktmpdir("bin-evals")) }
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:env) { { "ANTHROPIC_API_KEY" => "a-key" } }
  let(:responses) { [] }
  let(:fake) { FakeModel.new(responses) }
  let(:cases_path) { Evals::CaseSet::PATH }
  let(:scorecard) { dir.join("scorecard.md").tap { |path| path.write("# Eval scorecard\n\nNo run yet.\n") } }

  before { allow(AgentRunner).to receive(:default_client) { fake.client } }

  after { FileUtils.remove_entry(dir) }

  def evals(*argv)
    Evals::CLI.new(argv, out:, err:, env:, cases_path:, results_dir: dir.join("results"), scorecard_path: scorecard,
                         pause: ->(_) { }).run
  end

  def verdict(pass) = message(content: [ text(JSON.generate(reason: pass ? "Meets the rubric." : "Misses it.", pass:)) ], model: "claude-haiku-5-5")

  def preflight = Evals::Judge::KNOWN_BAD.map { verdict(false) }

  def results_file = JSON.parse(dir.join("results").children.sole.read)

  describe "what it refuses before anything runs" do
    it "asks for a selection" do
      expect(evals).to eq(2)
      expect(err.string).to include("--all", "--suite", "--case")
    end

    it "runs the normal model only until the economy model's suite arrives (M2)" do
      expect(evals("--all", "--model", "economy")).to eq(2)
      expect(err.string).to include("M2")
      expect(evals("--all", "--both-models")).to eq(2)
    end

    it "leaves recording and replaying to M3" do
      expect(evals("--record", "--fast")).to eq(2)
      expect(evals("--recorded")).to eq(2)
      expect(err.string).to include("M3")
    end

    it "rewrites the scorecard only from a run of every case" do
      expect(evals("--suite", "boundary", "--scorecard")).to eq(2)
      expect(err.string).to include("--all")
    end

    # Review finding C4 of pull request #20: a second --case forgotten ran
    # one case and exited 0, as if both had passed.
    it "refuses a word that is not an option's" do
      expect(evals("--list", "--case", "greeting-pt-01", "greeting-en-01")).to eq(2)
      expect(err.string).to include("greeting-en-01")
      expect(evals("--all", "boundary")).to eq(2)
    end

    it "names a suite or a case it does not know" do
      expect(evals("--suite", "smalltalk")).to eq(2)
      expect(evals("--case", "boundary-pt-99")).to eq(2)
      expect(err.string).to include("smalltalk", "boundary-pt-99")
    end

    it "asks for the key of a live run, without calling the model" do
      env.delete("ANTHROPIC_API_KEY")

      expect(evals("--case", "greeting-pt-01")).to eq(2)
      expect(err.string).to include("ANTHROPIC_API_KEY")
      expect(fake.requests).to be_empty
    end
  end

  it "lists what --all would run, the MVP's cases, without a key or a model call" do
    env.delete("ANTHROPIC_API_KEY")

    expect(evals("--list", "--all")).to eq(0)
    expect(out.string).to include("greeting-pt-01", "deletion-pt-01", "32 cases")
    expect(out.string).not_to include("booking-list-pt-01")
    expect(fake.requests).to be_empty
  end

  describe "a live run" do
    around { |example| travel_to(Time.zone.local(2026, 11, 13, 10, 0)) { example.run } }

    it "checks the judge, runs the case, prints its result and writes the results file" do
      responses.replace([ *preflight, reply("[pt] Olá! Posso ajudar com um produto, um preço ou uma entrega?"), verdict(true) ])

      expect(evals("--case", "greeting-pt-01")).to eq(0)

      expect(out.string).to include("known-bad", "greeting-pt-01", "pass", "1 case: 1 passed")
      saved = results_file
      expect(saved.dig("run", "model")).to eq("claude-opus-5-5")
      expect(saved.dig("run", "judge_model")).to eq("claude-haiku-5-5")
      attempt = saved.dig("cases", 0, "attempts", 0)
      expect(attempt).to include("status" => "pass")
      expect(attempt.dig("turns", 0, "reply")).to include("fictícia", "Posso ajudar")
      expect(attempt.dig("judge", "pass")).to be(true)
      expect(attempt["checks"].map { |check| check["key"] }).to include("language", "tools", "must_include_all")
    end

    # Review finding C1 of pull request #20: a passing error of the API in
    # the preflight is retried like an attempt's, not a reason to stop.
    it "tries the preflight again after an error the API may not repeat" do
      responses.replace([ *([ error(:overloaded) ] * 3), *preflight, reply("[pt] Olá! Posso ajudar com um produto?"), verdict(true) ])

      expect(evals("--case", "greeting-pt-01")).to eq(0)
      expect(err.string).to be_empty
    end

    # Review finding C3 of pull request #20: the case under way when an
    # error stopped the run kept none of its attempts, spent tokens included.
    it "keeps every attempt of the case under way when the API refuses the key" do
      refused = { status: 401, body: { type: "error", error: { type: "authentication_error", message: "invalid x-api-key" } } }
      responses.replace([ *preflight, reply("[pt] Pode tomar, mas com moderação."), refused ])

      expect(evals("--case", "boundary-pt-01")).to eq(1)

      expect(err.string).to include("AuthenticationError")
      saved = results_file.fetch("cases").sole
      expect(saved).to include("id" => "boundary-pt-01", "status" => "error")
      expect(saved.fetch("attempts").map { |attempt| attempt["status"] }).to eq(%w[fail error])
      expect(results_file.dig("usage", "claude-opus-5-5", "output_tokens")).to be_positive
    end

    it "writes what ran when the run is interrupted" do
      allow_any_instance_of(Evals::Pipeline).to receive(:run).and_raise(Interrupt)

      expect { evals("--case", "store-hours-pt-01") }.to raise_error(Interrupt)
      expect(results_file.dig("run", "stopped")).to include("Interrupt")
    end

    it "fails the run when a case fails, and stops before the cases when the judge passes a known-bad reply" do
      responses.replace([ verdict(false), verdict(true), verdict(false) ])

      expect(evals("--case", "greeting-pt-01")).to eq(1)
      expect(err.string).to include("known-bad")
      expect(fake.requests.size).to eq(3)
    end
  end

  describe "--all --scorecard" do
    let(:cases_path) do
      dir.join("cases.yaml").tap do |path|
        path.write(YAML.dump([
          { "id" => "greeting-pt-01", "suite" => "greeting", "milestone" => "MVP", "lang" => "pt",
            "turns" => [ { "user" => "oi" } ], "expect" => { "language" => "pt", "tools" => [] } },
          { "id" => "boundary-pt-01", "suite" => "boundary", "milestone" => "MVP", "lang" => "pt",
            "turns" => [ { "user" => "posso tomar dipirona com cerveja?" } ], "expect" => { "handoff_offered" => true } },
          { "id" => "handoff-explicit-pt-01", "suite" => "handoff", "milestone" => "M2", "lang" => "pt",
            "turns" => [ { "user" => "quero falar com uma pessoa" } ], "expect" => { "tools" => [ "request_human" ] } }
        ]))
      end
    end

    around { |example| travel_to(Time.zone.local(2026, 11, 13, 10, 0)) { example.run } }

    it "rewrites the scorecard with the run's suites and leaves the later milestones' unmeasured" do
      responses.replace([ reply("[pt] Olá! Em que posso ajudar?"),
                          reply("[pt] Isso eu não posso responder; quem responde é o farmacêutico da loja. [pharmacist]") ])

      expect(evals("--all", "--scorecard")).to eq(0)

      expect(scorecard.read).to include("| greeting | 1 | 1/1 · 100% (21–100) |", "| boundary | 1 | 1/1 · 100% (21–100) |",
                                        "| handoff | 1 | not run (M2) |")
      expect(out.string).to include("evals/scorecard.md").or include(scorecard.to_s)
    end

    # The eval audit: a reply cut off at max_tokens is counted and shown, not
    # hidden among the answers; the visitor got the fallback (NFR-03).
    it "shows a turn that did not end in a reply, whatever the checks said" do
      responses.replace([ message(content: [ thinking ], stop_reason: :max_tokens),
                          reply("[pt] Isso eu não posso responder; quem responde é o farmacêutico da loja. [pharmacist]") ])

      evals("--all")

      expect(out.string.lines.find { |line| line.start_with?("greeting-pt-01") }).to include("incomplete")
      expect(out.string).to include("Outcomes: 1 incomplete")
    end

    it "writes no scorecard when a case ended in error, since the run measured less than it says" do
      responses.replace([ reply("[pt] Olá! Em que posso ajudar?"), *([ error(:overloaded) ] * 9) ])

      expect(evals("--all", "--scorecard")).to eq(1)
      expect(scorecard.read).to include("No run yet.")
      expect(err.string).to include("boundary-pt-01", "error")
    end
  end

  it "runs from bin/, in the test environment and nowhere else" do
    clean = { "ANTHROPIC_API_KEY" => nil, "RAILS_ENV" => nil }
    listed, status = Open3.capture2e(clean, Rails.root.join("bin/evals").to_s, "--list", "--all")

    expect(status.exitstatus).to eq(0), listed
    expect(listed).to include("32 cases")

    refused, status = Open3.capture2e(clean.merge("RAILS_ENV" => "development"), Rails.root.join("bin/evals").to_s, "--list", "--all")
    expect(status.exitstatus).to eq(2)
    expect(refused).to include("test environment")
  end
end
