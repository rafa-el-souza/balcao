require "rails_helper"
require "open3"

# The budget's ledger and its gate (FR-14, threat model SR-02, ADR-0003):
# every model call is charged to the calendar month in São Paulo at the price
# table's prices, and the month's mode is read before any model call. In the
# MVP the automatic mode is normal or, at the cap, paused; economy, the daily
# slice and the operator's notification arrive at M3 (design §9.1).
RSpec.describe "FR-14 SR-02 the budget: the ledger of model calls and the monthly cap's pause" do
  around do |example|
    @default_cap = Rails.configuration.x.budget_cap_usd
    Rails.configuration.x.budget_cap_usd = BigDecimal("10")
    example.run
  ensure
    Rails.configuration.x.budget_cap_usd = @default_cap
  end

  let(:turn) { create(:turn) }

  def usage(model: "claude-opus-5-5", input: 1200, output: 80, write: 0, read: 3000)
    AgentRunner::Usage.new(model:, input_tokens: input, output_tokens: output, cache_creation_tokens: write,
                           cached_tokens: read)
  end

  def month(at = Time.current) = BudgetState.find_by(month: at.in_time_zone.strftime("%Y-%m"))

  describe "the cap" do
    it "is US$ 100 unless the destination sets another (ADR-0003)" do
      expect(@default_cap).to eq(BigDecimal("100"))
      expect(Budget.cap).to eq(BigDecimal("10"))
    end
  end

  describe "the ledger" do
    it "writes one usage record per attempt, priced, and adds the cost to the month's spend" do
      travel_to Time.zone.local(2026, 11, 15, 12, 0) do
        total = Budget.charge!(turn, [ usage, usage(model: "claude-opus-5", input: 1000, output: 100, read: 0) ])

        expect(total).to eq(BigDecimal("0.007") + BigDecimal("0.0075"))
        expect(turn.usage_records.order(:created_at).map { |record| [ record.model, record.cost_usd ] })
          .to eq([ [ "claude-opus-5-5", BigDecimal("0.007") ], [ "claude-opus-5", BigDecimal("0.0075") ] ])
        expect(turn.usage_records.first).to have_attributes(input_tokens: 1200, output_tokens: 80, cached_tokens: 3000,
                                                            cache_creation_tokens: 0)
        expect(month.spent_usd).to eq(BigDecimal("0.0145"))
      end
    end

    it "charges nothing and opens no month for a call that reported no usage (a failed one)" do
      expect(Budget.charge!(turn, [])).to eq(0)
      expect(UsageRecord.count).to eq(0)
      expect(BudgetState.count).to eq(0)
    end

    it "keeps the month's spend after the seven-day purge has deleted its usage records (FR-15)" do
      travel_to Time.zone.local(2026, 11, 2, 12, 0) do
        Budget.charge!(turn, [ usage ])
      end
      UsageRecord.delete_all

      travel_to Time.zone.local(2026, 11, 20, 12, 0) do
        expect(month.spent_usd).to eq(BigDecimal("0.007"))
      end
    end

    it "charges the month of São Paulo, where 23:30 on the 30th is already December in UTC" do
      travel_to Time.zone.local(2026, 11, 30, 23, 30) do
        Budget.charge!(turn, [ usage ])
      end

      expect(BudgetState.sole.month).to eq("2026-11")
    end

    # Turns of different conversations run at once (three worker threads):
    # each charge adds to the spend the database holds, under the row's lock,
    # never to a copy read before another charge committed.
    it "adds to the spend the database holds, never to a copy read before another charge" do
      stale = BudgetState.for_month!
      BudgetState.where(id: stale.id).update_all(spent_usd: BigDecimal("5"))
      allow(BudgetState).to receive(:for_month!).and_return(stale)

      Budget.charge!(turn, [ usage ])

      expect(stale.reload.spent_usd).to eq(BigDecimal("5.007"))
    end

    it "charges the spend alone, leaving the mode to the read that comes next" do
      BudgetState.for_month!.update!(spent_usd: BigDecimal("9.995"))

      Budget.charge!(turn, [ usage ])

      expect(month).to have_attributes(spent_usd: BigDecimal("10.002"), automatic_mode: "normal")
    end
  end

  # Review finding S3 of pull request #29: the row and the log say what the
  # cap says when the mode is read, whatever changed it (a charge, a cap a
  # deploy changed), and what serves when a forced mode wins.
  describe "the record of the automatic mode" do
    before { allow(Rails.logger).to receive(:warn) }

    it "writes the pause into the month's row and one line, at the first read past the cap" do
      BudgetState.for_month!.update!(spent_usd: BigDecimal("9.995"))
      Budget.charge!(turn, [ usage ])

      2.times { expect(Budget.mode).to eq("paused") }

      expect(month.automatic_mode).to eq("paused")
      expect(Rails.logger).to have_received(:warn)
        .with("budget: #{month.month}'s automatic mode is paused at US$ 10.00 of its cap of US$ 10.00").once
    end

    it "says which forced mode serves past the cap, never that the demo paused" do
      BudgetState.for_month!.update!(spent_usd: BigDecimal("12"), forced_mode: "normal")

      expect(Budget.mode).to eq("normal")

      expect(Rails.logger).to have_received(:warn)
        .with(/automatic mode is paused at US\$ 12\.00 of its cap of US\$ 10\.00; the forced normal mode serves\z/)
    end

    # Review finding R1 of pull request #29: a forced economy pauses until
    # the eval run allows the economy model; the line says so.
    it "never says a forced economy serves while the month pauses" do
      BudgetState.for_month!.update!(spent_usd: BigDecimal("12"), forced_mode: "economy")

      expect(Budget.mode).to eq("paused")

      expect(Rails.logger).not_to have_received(:warn).with(/the forced economy mode serves/)
      expect(Rails.logger).to have_received(:warn)
        .with(/automatic mode is paused at US\$ 12\.00 of its cap of US\$ 10\.00; the forced economy mode may not serve yet, so the demo pauses\z/)
    end

    # Review finding R2 of pull request #29: a new month is a change too.
    it "writes one line when the next month opens, the resume of a month the cap paused" do
      travel_to(Time.zone.local(2026, 11, 30, 22, 0)) do
        BudgetState.for_month!.update!(spent_usd: BigDecimal("12"))
        expect(Budget.mode).to eq("paused")
      end
      travel_to(Time.zone.local(2026, 12, 1, 0, 1)) { 2.times { expect(Budget.mode).to eq("normal") } }

      expect(Rails.logger).to have_received(:warn)
        .with("budget: 2026-12's automatic mode is normal at US$ 0.00 of its cap of US$ 10.00").once
    end

    it "writes the opening line when a charge opens the month, as at the turn of the month" do
      travel_to(Time.zone.local(2026, 12, 1, 0, 0, 1)) { Budget.charge!(turn, [ usage ]) }

      expect(Rails.logger).to have_received(:warn).with(/\Abudget: 2026-12's automatic mode is normal/).once
    end

    it "follows a cap a deploy lowered below the spend, and one it raised" do
      BudgetState.for_month!.update!(spent_usd: BigDecimal("5"))
      Rails.configuration.x.budget_cap_usd = BigDecimal("4")

      expect(Budget.mode).to eq("paused")
      expect(month.automatic_mode).to eq("paused")

      Rails.configuration.x.budget_cap_usd = BigDecimal("15")

      expect(Budget.mode).to eq("normal")
      expect(month.automatic_mode).to eq("normal")
      expect(Rails.logger).to have_received(:warn).with(/automatic mode is normal at US\$ 5\.00 of its cap of US\$ 15\.00\z/)
    end
  end

  describe "the mode, read before any model call" do
    it "is normal for a month with nothing spent, or none charged yet" do
      expect(Budget.mode).to eq("normal")
    end

    it "is normal below the cap" do
      BudgetState.for_month!.update!(spent_usd: BigDecimal("9.99"))

      expect(Budget.mode).to eq("normal")
    end

    it "is paused from the cap on, whatever the row's last written mode" do
      BudgetState.for_month!.update!(spent_usd: BigDecimal("10"), automatic_mode: "normal")

      expect(Budget.mode).to eq("paused")
    end

    it "follows a cap the destination raised: the same spend no longer pauses" do
      BudgetState.for_month!.update!(spent_usd: BigDecimal("10"), automatic_mode: "paused")
      Rails.configuration.x.budget_cap_usd = BigDecimal("15")

      expect(Budget.mode).to eq("normal")
    end

    it "starts the next calendar month over in normal (FR-14)" do
      travel_to(Time.zone.local(2026, 11, 30, 22, 0)) { BudgetState.for_month!.update!(spent_usd: BigDecimal("12")) }

      travel_to(Time.zone.local(2026, 12, 1, 0, 1)) { expect(Budget.mode).to eq("normal") }
    end

    it "keeps a forced mode over the automatic one until it is released (FR-14's kill switch)" do
      BudgetState.for_month!.update!(forced_mode: "paused")
      expect(Budget.mode).to eq("paused")

      BudgetState.for_month!.update!(forced_mode: "normal", spent_usd: BigDecimal("11"))
      expect(Budget.mode).to eq("normal")
    end

    # The hunter's F1 on pull request #55: the operator forced a mode on the
    # month's row itself, so a forced economy the gate kept closed paused
    # the demo and no line said so. Forcing goes through the budget, which
    # writes the month's line, the forced mode named when it may not serve,
    # and answers what serves now.
    it "forces a mode by the budget, saying in the month's line what serves, and releases it" do
      travel_to Time.zone.local(2026, 11, 20, 12, 0) do
        allow(Rails.logger).to receive(:warn)
        Budget.mode

        expect(Budget.force!(:economy)).to eq(Budget::Status.new(mode: "paused", forced: true))
        expect(Rails.logger).to have_received(:warn)
          .with("budget: 2026-11's automatic mode is normal at US$ 0.00 of its cap of US$ 10.00; " \
                "the forced economy mode may not serve yet, so the demo pauses")
        expect(BudgetState.for_month!.forced_mode).to eq("economy")

        Rails.configuration.x.economy_allowed = true
        expect(Budget.force!(:economy)).to eq(Budget::Status.new(mode: "economy", forced: true))
        expect(Rails.logger).to have_received(:warn).with(/; the forced economy mode serves\z/)

        expect(Budget.force!(nil)).to eq(Budget::Status.new(mode: "normal", forced: false))
        expect(BudgetState.for_month!.forced_mode).to be_nil
      end
    end

    # ADR-0003: economy serves only while the boundary suite last passed at
    # 100 % on the economy model, the full eval run's word, which the app
    # reads at boot (the suite starts each example with it closed).
    it "pauses a forced economy while the gate is closed, and serves it once the eval run allowed it" do
      BudgetState.for_month!.update!(forced_mode: "economy")
      expect(Budget.mode).to eq("paused")

      Rails.configuration.x.economy_allowed = true
      expect(Budget.mode).to eq("economy")
    end
  end

  describe "ADR-0003's gate, the full eval run's word, read at boot" do
    let(:dir) { Pathname(Dir.mktmpdir("economy-gate")) }
    let(:route) { ModelPolicy.route("economy") }
    let(:run) do
      "model: #{route.model}\neffort: #{route.effort}\nprompt: #{PromptDigest.prompt}\ntools: #{PromptDigest.tools}\n" \
        "commit: ec17b12\nrun_at: '2026-11-20T04:00:00Z'\n"
    end

    before { allow(Rails.logger).to receive(:warn) }
    after { FileUtils.remove_entry(dir) }

    def gate(content) = dir.join("economy_allowed.yml").tap { |path| path.binwrite(content) }

    it "allows the economy model on a mapping whose economy_allowed is true, written by a run on the economy route" do
      expect(Budget.read_economy_allowed(gate("economy_allowed: true\n#{run}"))).to be(true)
      expect(Budget.read_economy_allowed(gate("economy_allowed: false\n#{run}"))).to be(false)
      expect(Rails.logger).not_to have_received(:warn)
    end

    it "reads no file as not allowed, with no line, as before the first full run" do
      expect(Budget.read_economy_allowed(dir.join("economy_allowed.yml"))).to be(false)
      expect(Rails.logger).not_to have_received(:warn)
    end

    # Review finding S6 of pull request #29: a list raised TypeError and a
    # scalar NoMethodError, so with economy forced every session and poll
    # answered 500. The file is read once, at boot, and anything but the
    # mapping the run writes reads as "not allowed", said at warn.
    it "reads anything else as not allowed, with a warning line, and never raises" do
      files = {
        "a list" => "- true\n", "a scalar" => "true\n", "a string's true" => "economy_allowed: \"true\"\n#{run}",
        "no key" => "allowed: true\n#{run}", "an empty file" => "", "an unquoted time" => "economy_allowed: true\nrun_at: 2026-11-20T04:00:00Z\n",
        "bytes that are not text" => "\xFF\xFE\x00 economy_allowed: true".b, "an alias" => "&a [*a]\n"
      }
      files.each { |what, content| expect(Budget.read_economy_allowed(gate(content))).to be(false), what }
      expect(Budget.read_economy_allowed(dir)).to be(false)

      expect(Rails.logger).to have_received(:warn).with(/\Abudget: .+; the economy model may not serve\z/).exactly(files.size + 1).times
    end

    # The boundary passed on the model the run measured: a gate written
    # before the economy route changed model or effort no longer speaks for it.
    it "reads a gate written by a run on another model or effort as not allowed, and says which" do
      expect(Budget.read_economy_allowed(gate("economy_allowed: true\n#{run.sub(route.model, "claude-haiku-4-5")}"))).to be(false)
      expect(Budget.read_economy_allowed(gate("economy_allowed: true\n#{run.sub("effort: #{route.effort}", "effort: max")}"))).to be(false)

      expect(Rails.logger).to have_received(:warn).with(/claude-haiku-4-5.*#{route.model}/)
      expect(Rails.logger).to have_received(:warn).with(/at "max" effort/)
    end

    # The hunter's F2 on pull request #55: the boundary was measured on the
    # system prompt the model read and the tools it was offered, so a gate
    # written before either changed does not speak for the code that serves.
    it "reads a gate written for another system prompt or tool set as not allowed, and says which" do
      expect(Budget.read_economy_allowed(gate("economy_allowed: true\n#{run.sub(PromptDigest.prompt, "0123456789abcdef")}"))).to be(false)
      expect(Budget.read_economy_allowed(gate("economy_allowed: true\n#{run.sub(PromptDigest.tools, "fedcba9876543210")}"))).to be(false)
      expect(Budget.read_economy_allowed(gate("economy_allowed: true\n#{run.sub(/^prompt: .*\n/, "")}"))).to be(false)

      expect(Rails.logger).to have_received(:warn).with(/system prompt "0123456789abcdef".*#{PromptDigest.prompt}/)
      expect(Rails.logger).to have_received(:warn).with(/tools "fedcba9876543210".*#{PromptDigest.tools}/)
      expect(Rails.logger).to have_received(:warn).with(/system prompt nil/)
    end

    # The digests follow what the model reads: a word of the prompt or of a
    # tool's description is another digest.
    it "digests the system prompt the model reads and the tools it is offered" do
      expect(PromptDigest.prompt).to eq(TurnTrace.prompt_summary["balcao.system_prompt.sha256"]).and match(/\A\h{16}\z/)
      expect(PromptDigest.tools).to match(/\A\h{16}\z/)

      changed = Class.new(Tools::SearchProducts) { doc "Search the catalogue." }
      expect(PromptDigest.tools([ Tools::GetStoreInfo, changed, Tools::CreateReservation ])).not_to eq(PromptDigest.tools)
    end

    it "is read when the app boots, so the file a deploy brought serves until the next deploy" do
      boot = lambda do |answer|
        probe = <<~RUBY
          require "yaml"
          answer = #{answer.inspect}
          YAML.singleton_class.prepend(Module.new do
            define_method(:safe_load_file) { |path, **options| path.to_s.end_with?("evals/economy_allowed.yml") ? answer : super(path, **options) }
          end)
          require "./config/environment"
          answer = nil
          puts Budget.economy_allowed?
        RUBY
        env = ProductionEnv.complete
          .merge("APP_HOST" => "demo.example", "RAILS_ENV" => "production", "DATABASE_URL" => nil, "RAILS_LOG_LEVEL" => "fatal")
        Open3.capture3(env, "ruby", "-e", probe, chdir: Rails.root.to_s)
      end

      out, err, status = boot.call({ "economy_allowed" => true, "model" => route.model, "effort" => route.effort,
                                     "prompt" => PromptDigest.prompt, "tools" => PromptDigest.tools })
      expect([ status.success?, out ]).to eq([ true, "true\n" ]), err

      out, err, status = boot.call([ true ])
      expect([ status.success?, out ]).to eq([ true, "false\n" ]), err
    end
  end
end
