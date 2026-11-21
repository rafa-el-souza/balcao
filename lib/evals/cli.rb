require "optparse"
require_relative "scorecard"
require_relative "economy_gate"
require_relative "recording"
require_relative "replay"

# bin/evals' command line (evals/README.md, Running). It reads and checks
# every case first, selects some, and either lists them or runs them live
# through the app's pipeline (Evals::Pipeline) on the normal model, the
# economy model (--model economy) or both, one after the other
# (--both-models), the rubrics judged by the economy model once it has failed
# its known-bad replies, each boundary case N times with --repeat N
# (Evals::Runner). It prints each case as it ends and a table per suite and
# model, writes every attempt whole to evals/results/ (gitignored: replies,
# checks, verdicts, spans and tokens), one file per model, and with --all
# --scorecard rewrites evals/scorecard.md, unless a case ended in error,
# since the run then measured less than the scorecard would say. On both
# models it also rewrites ADR-0003's gate, evals/economy_allowed.yml, from
# the boundary on the economy model alone (Evals::EconomyGate).
#
# The fast subset (the cases marked fast: true, of a delivered milestone) is
# recorded live on the normal model with --record --fast, each case's first
# passing attempt into evals/recordings/<case id>.json, and replayed with
# --recorded, with no key, as CI does on every pull request (Evals::Recording,
# Evals::Replay).
#
# Exit status: 0 when every case run passed, 1 when one failed or ended in
# error, was not recorded or the run stopped, 2 for a command it does not
# take.
module Evals
  class CLI
    BANNER = "Usage: bin/evals (--all | --suite NAME... | --case ID... | --fast) [--model normal|economy | --both-models] " \
             "[--repeat N] [--scorecard] [--list]\n" \
             "       bin/evals --record (--fast | --case ID...)\n" \
             "       bin/evals --recorded [--case ID...]".freeze
    MODES = ModelPolicy::ROUTES.keys.freeze

    class Usage < StandardError; end

    def initialize(argv, out: $stdout, err: $stderr, env: ENV, cases_path: CaseSet::PATH,
                   results_dir: Rails.root.join("evals/results"), scorecard_path: Scorecard::PATH,
                   economy_gate_path: EconomyGate::PATH, recordings_dir: Recording::DIR, recording_client: nil, git: nil,
                   pause: ->(seconds) { sleep(seconds) })
      @argv = argv
      @out = out
      @err = err
      @env = env
      @cases_path = cases_path
      @results_dir = Pathname(results_dir)
      @scorecard_path = Pathname(scorecard_path)
      @economy_gate_path = Pathname(economy_gate_path)
      @recordings_dir = Pathname(recordings_dir)
      # A recording run's client for each attempt: the SDK's, with the key and
      # the recorder as its middleware.
      @recording_client = recording_client || lambda do |recorder|
        Anthropic::Client.new(api_key: @env["ANTHROPIC_API_KEY"], max_retries: AgentRunner::MAX_RETRIES, middleware: [ recorder ])
      end
      @git = git || self.class.git_in(Rails.root)
      @pause = pause
    end

    # TERM and HUP (a kill, a timeout, a closed session) as Ctrl-C: an
    # Interrupt, which the run rescues to write what ran. Left to Ruby, they
    # raised SignalException, which nothing rescued, and the run's record was
    # lost whole (the review of #62, H1). A signal the run started with
    # ignored, as nohup leaves HUP, stays ignored, so a run meant to outlive
    # its session does (the fix review's R1). bin/evals installs them.
    def self.trap_signals!
      %w[TERM HUP].each do |signal|
        previous = Signal.trap(signal) { raise Interrupt }
        Signal.trap(signal, previous) if previous == "IGNORE"
      end
    end

    # git in the directory: its output, or nil when git failed. A checkout
    # git refuses to read prints nothing, which read as a clean tree (the
    # fix review's R3 on pull request #55).
    def self.git_in(dir)
      lambda do |*args|
        output = IO.popen([ "git", *args ], chdir: dir, err: File::NULL, &:read)
        output if $?.success?
      end
    end

    def run
      options = parse
      return help if options[:help]

      cases = CaseSet.load(@cases_path)
      selected = select(cases, options)
      repeated!(selected, options[:repeat])
      return list(selected, options[:repeat]) if options[:list]
      return replay(cases, selected, every: options[:ids].empty?) if options[:recorded]
      # The gate speaks for a commit, so the run that writes it reads one
      # (review finding C2 of pull request #55), and a tree git cannot read
      # is no commit's (the fix review's R3).
      if options[:both] && options[:scorecard]
        changed = changes
        raise Usage, "--both-models --scorecard writes the economy model's gate, which speaks for a commit, and git could not read " \
                     "the tree (git status fails): run it from a checkout git reads" if changed.nil?
        raise Usage, "--both-models --scorecard writes the economy model's gate, which speaks for a commit, and the tree has " \
                     "uncommitted changes (git status lists them): commit or stash them first" if changed.any?
      end
      raise Usage, "ANTHROPIC_API_KEY is blank: a live run needs the dev/eval key in the environment" if @env["ANTHROPIC_API_KEY"].to_s.strip.empty?

      live(cases, selected, scorecard: options[:scorecard], repeat: options[:repeat], modes: options[:modes], record: options[:record])
    rescue Usage, OptionParser::ParseError => e
      @err.puts("bin/evals: #{e.message}", BANNER)
      2
    rescue CaseSet::Invalid => e
      @err.puts("bin/evals: #{e.message}")
      1
    end

    private

    def parse
      options = { suites: [], ids: [] }
      parser = OptionParser.new do |opts|
        opts.banner = BANNER
        opts.on("--all", "Every case of a delivered milestone (#{RUNNABLE_MILESTONES.join(", ")}) and of a delivered suite " \
                         "(#{RUNNABLE_SUITES.map { |milestone, suites| "#{milestone}'s #{suites.join(", ")}" }.join("; ")})") { options[:all] = true }
        opts.on("--suite NAME", "A suite's cases of a delivered milestone; repeatable") { |name| options[:suites] << name }
        opts.on("--case ID", "One case, whatever its milestone; repeatable") { |id| options[:ids] << id }
        opts.on("--fast", "The fast subset: every case marked fast: true of a delivered milestone") { options[:fast] = true }
        opts.on("--record", "Record the selected fast cases live on the normal model into #{Recording::DIR.relative_path_from(Rails.root)}/") do
          options[:record] = true
        end
        opts.on("--recorded", "Replay the fast subset's recordings (or the --case ones), with no key: CI's run") { options[:recorded] = true }
        opts.on("--model MODEL", "#{MODES.join(" or ")} (normal when left out)") { |model| options[:model] = model }
        opts.on("--both-models", "Every selected case on the normal model, then on the economy model") { options[:both] = true }
        opts.on("--repeat N", Integer, "Each #{Runner::REPEATED_SUITES.to_sentence(locale: :en)} case N times (#{Runner::REPEAT.min} to #{Runner::REPEAT.max}), every attempt graded") do |count|
          options[:repeat] = count
        end
        opts.on("--scorecard", "With --all: rewrite evals/scorecard.md") { options[:scorecard] = true }
        opts.on("--list", "List the selected cases and stop: no key, no model call") { options[:list] = true }
        opts.on("-h", "--help") { options[:help] = parser }
      end
      stray = parser.parse(@argv)
      raise Usage, "#{stray.join(" ")}: not an option's value; each case and suite takes its own --case or --suite" if stray.any?

      check(options)
    end

    def check(options)
      recording!(options)
      raise Usage, "--model #{options[:model]}: it takes #{MODES.join(" or ")}" if options[:model] && !MODES.include?(options[:model])
      raise Usage, "--both-models runs the normal model and then the economy model: leave --model out" if options[:both] && options[:model]

      options[:modes] = options[:both] ? MODES : [ options[:model] || "normal" ]
      if options[:scorecard] && !options[:modes].include?("normal")
        raise Usage, "--scorecard rewrites the scorecard from a run with the normal model in it: --model normal, or --both-models " \
                     "for both columns and the economy model's gate"
      end
      # The gate rests on each boundary case run three times or more (design
      # FR-09; review finding C1 of pull request #55).
      if options[:both] && options[:scorecard] && options[:repeat].nil?
        raise Usage, "--both-models --scorecard writes the economy model's gate, which rests on each boundary case run three " \
                     "times or more (FR-09): add --repeat 3"
      end

      kinds = [ options[:all], options[:suites].any?, options[:ids].any?, options[:fast] ].count(&:itself)
      raise Usage, "choose one of --all, --suite, --case or --fast" unless kinds == 1 || options[:help] || (options[:recorded] && kinds.zero?)
      raise Usage, "--scorecard rewrites the scorecard from --all alone" if options[:scorecard] && !options[:all]
      raise Usage, "--scorecard and --list do not go together" if options[:scorecard] && options[:list]
      if options[:repeat] && !Runner::REPEAT.cover?(options[:repeat])
        raise Usage, "--repeat #{options[:repeat]}: it takes #{Runner::REPEAT.min} to #{Runner::REPEAT.max}: with fewer one failure " \
                     "leaves a single pass, and more costs what a typo would"
      end

      options
    end

    # A recording is made and replayed on the normal route alone, one attempt
    # a case, of the fast subset's cases, with no scorecard: --record takes
    # --fast or --case, --recorded nothing or --case.
    def recording!(options)
      return unless options[:record] || options[:recorded]

      raise Usage, "--record records and --recorded replays: choose one" if options[:record] && options[:recorded]

      flag = options[:record] ? "--record" : "--recorded"
      others = { "--all" => options[:all], "--suite" => options[:suites].any?, "--model" => options[:model], "--both-models" => options[:both],
                 "--repeat" => options[:repeat], "--scorecard" => options[:scorecard] }.select { |_, given| given }.keys
      others << "--fast" if options[:recorded] && options[:fast]
      raise Usage, "#{flag} takes #{options[:record] ? "--fast or --case" : "--case or nothing"}, not #{others.join(", ")}: " \
                   "the fast subset is recorded on the normal model, one attempt a case" if others.any?
      raise Usage, "--record takes --fast or --case" if options[:record] && !options[:fast] && options[:ids].empty?
    end

    # --repeat applies to the boundary and injection suites (README, Flakiness
    # policy), so a selection with none of their cases would repeat nothing.
    def repeated!(selected, repeat)
      return if repeat.nil? || selected.any? { |kase| Runner::REPEATED_SUITES.include?(kase.suite) }

      raise Usage, "--repeat applies to the #{Runner::REPEATED_SUITES.to_sentence(locale: :en)} suites, and the selection has no case of them"
    end

    def help
      @out.puts(BANNER)
      0
    end

    def select(cases, options)
      return cases.runnable if options[:all]
      return cases.runnable.select(&:fast) if options[:fast] || (options[:recorded] && options[:ids].empty?)

      if options[:ids].any?
        missing = options[:ids].reject { |id| cases.find(id) }
        raise Usage, "no case #{missing.join(", ")} in #{@cases_path}" if missing.any?

        selected = options[:ids].uniq.map { |id| cases.find(id) }
        outside = selected.reject { |kase| kase.fast && kase.runnable? }.map(&:id)
        if (options[:record] || options[:recorded]) && outside.any?
          raise Usage, "#{outside.join(", ")}: a recording is kept for the fast subset alone, the cases marked fast: true of a " \
                       "delivered milestone"
        end

        return selected
      end
      unknown = options[:suites] - SUITES
      raise Usage, "no suite #{unknown.join(", ")}; the suites are #{SUITES.join(", ")}" if unknown.any?

      selected = cases.runnable.select { |kase| options[:suites].include?(kase.suite) }
      raise Usage, "no case of a delivered milestone in #{options[:suites].join(", ")}" if selected.empty?

      selected
    end

    def list(selected, repeat)
      selected.each do |kase|
        repeated = ", #{repeat} attempts" if repeat && Runner::REPEATED_SUITES.include?(kase.suite)
        @out.puts(line(kase, kase.milestone, "#{kase.messages.size} message(s)#{", rubric" if kase.rubric}#{repeated}"))
      end
      @out.puts("#{selected.size} #{"case".pluralize(selected.size)}")
      0
    end

    # The selection on each model in turn, one report each; a run that
    # stopped on one model does not go on to the next. The judge's preflight
    # runs once, before the first model's cases.
    def live(cases, selected, scorecard:, repeat:, modes:, record: false)
      ActiveRecord::Migration.maintain_test_schema!
      @unrecorded = []
      judge = Judge.new(client: AgentRunner.default_client)
      # The commit the run measured is the one it started from, read once: a
      # commit made while the normal model ran is not the economy model's
      # (the fix review's R2 on pull request #55).
      head = commit
      dirty = dirty?
      reports = []
      modes.each do |mode|
        route = ModelPolicy.route(mode)
        report = Report.new(argv: @argv, route:, judge:, started_at: Time.current, commit: head, dirty:, repeat:)
        reports << report
        @out.puts("bin/evals: #{selected.size} #{"case".pluralize(selected.size)} on #{route.model} (effort #{route.effort}), " \
                  "judged by #{judge.model}#{", each #{Runner::REPEATED_SUITES.to_sentence(locale: :en)} case #{repeat} times" if repeat}")
        break unless run_on(report, judge, selected, route, repeat:, first: reports.one?, record: ("#{head}#{"-dirty" if dirty}" if record))
      rescue Interrupt, StandardError
        # What ran is written before the interruption or the bug goes on.
        finish(reports, cases, scorecard: false, headed: modes.many?)
        raise
      end
      # A model whose run never started is said, not left to the missing
      # results file (the verifier's L2 on pull request #55).
      modes.drop(reports.size).each { |mode| @err.puts("bin/evals: the run on the #{mode} model did not start: the run stopped") }
      finish(reports, cases, scorecard:, headed: modes.many?)
    end

    # Runs the selection on one route; false when the run stopped. record:
    # the commit a recording run writes into each recording, nil otherwise.
    def run_on(report, judge, selected, route, repeat:, first:, record: nil)
      if first && selected.any?(&:rubric)
        report.preflight = preflight(judge)
        @out.puts("judge: failed the #{Judge.known_bad.size} known-bad replies, as it must")
      end
      pipeline = Pipeline.new(mode: route.mode)
      pipeline = Recording::Pipeline.new(pipeline, client: @recording_client) if record
      runner = Runner.new(pipeline:, checks: Checks.new(phrases:), judge:, route:, repeat:, pause: @pause)
      runner.call(selected) do |result|
        report.results << result
        @out.puts(outcome(result))
        recorded(pipeline, result, record) if record
      end
      true
    rescue Judge::Unfit, Judge::Error, Runner::Fatal, Anthropic::Errors::APIError => e
      stopped(report, e)
      false
    rescue Interrupt, StandardError => e
      stopped(report, e)
      raise
    ensure
      report.finish!
    end

    # The case under way when the run stopped, with its attempts (review
    # finding C3 of pull request #20), Ctrl-C's too (#55's L6). The report is
    # marked stopped before anything is printed: with the terminal gone a
    # print raises, and the record must still say the run stopped (the
    # review of #62, V3).
    def stopped(report, error)
      kept = error.result if (error.is_a?(Runner::Fatal) || error.is_a?(Runner::Interrupted)) && error.result
      report.results << kept if kept
      report.stopped = "#{error.class}: #{error.message}"
      @out.puts(outcome(kept)) if kept
      @err.puts("bin/evals: the run stopped: #{report.stopped}")
    end

    # The recording of a case's first passing attempt, or why none was
    # written, which fails the run.
    def recorded(pipeline, result, commit)
      unwritten = pipeline.write(result, dir: @recordings_dir, commit:)
      @unrecorded << result.kase.id if unwritten
      path = Recording.path(result.kase, @recordings_dir)
      @out.puts("  #{unwritten || "recorded: #{path.to_s.delete_prefix("#{Rails.root}/")}"}")
    end

    # The fast subset replayed from its recordings (Evals::Replay), with no
    # key; with every case selected, a recording of no selected case fails
    # the run too, since nothing would replay it.
    def replay(cases, selected, every:)
      ActiveRecord::Migration.maintain_test_schema!
      route = ModelPolicy.route("normal")
      @out.puts("bin/evals: #{selected.size} recorded #{"case".pluralize(selected.size)} replayed on #{route.model} " \
                "(effort #{route.effort}), with no key and no judge")
      results = Replay.new(pipeline: Pipeline.new(mode: route.mode), checks: Checks.new(phrases:), route:, dir: @recordings_dir)
                      .call(selected) { |result| @out.puts(outcome(result)) }
      orphans = every ? @recordings_dir.glob("*.json").map { |path| path.basename(".json").to_s } - selected.map(&:id) : []
      orphans.each { |id| @out.puts("#{id}: evals/recordings/#{id}.json records no case of the fast subset; delete it or mark the case fast") }
      passed = results.count { |result| result.status == :pass }
      @out.puts("", "#{passed} of #{results.size} recorded #{"case".pluralize(results.size)} passed" \
                    "#{"; #{orphans.size} #{"recording".pluralize(orphans.size)} of no case" if orphans.any?}")
      passed == results.size && orphans.empty? ? 0 : 1
    end

    # The preflight meets the API as an attempt does: a broken verdict or an
    # error the API may not repeat is tried again after the runner's wait,
    # three tries in all; a refused key or request stops the run, and so does
    # a judge that passes a known-bad reply (review finding C1 of pull
    # request #20).
    def preflight(judge)
      tries = 0
      begin
        judge.preflight!
      rescue Judge::Error, Anthropic::Errors::APIError => e
        tries += 1
        raise if Runner::FATAL_ERRORS.include?(e.class.name) || tries >= Runner::ERRORS

        @pause.call(rand(Runner::RETRY_WAIT))
        retry
      end
    end

    # headed: the run was on more than one model, so each table names its own.
    # The results files are written before anything is printed, so a closed
    # terminal, whose prints raise, costs no record (the review of #62, H1).
    def finish(reports, cases, scorecard:, headed:)
      paths = reports.map { |report| report.write(@results_dir) }
      reports.zip(paths).each do |report, path|
        @out.puts(*[ "", ("On the #{report.route.mode} model, #{report.route.model}:" if headed), *report.summary ].compact)
        @out.puts("Results: #{path}")
      end
      write_scorecard(reports, cases) if scorecard
      ok = reports.all? { |report| report.stopped.nil? && report.results.all? { |result| result.status == :pass } }
      @err.puts("bin/evals: not recorded: #{@unrecorded.join(", ")}") if @unrecorded.present?
      ok && @unrecorded.blank? ? 0 : 1
    end

    # The scorecard from the normal model's report, with the economy model's
    # column and ADR-0003's gate when the run had both (EconomyGate). The gate
    # the app reads is written first, and each file through a temporary one
    # renamed, so a run that breaks while writing leaves no half of either
    # (#55's L1, the owner, 2026-11-20).
    def write_scorecard(reports, cases)
      errored = reports.flat_map(&:results).select { |result| result.status == :error }.map { |result| result.kase.id }.uniq
      if reports.any?(&:stopped) || errored.any?
        @err.puts("bin/evals: scorecard not written: #{reports.any?(&:stopped) ? "the run stopped" : "#{errored.join(", ")} ended in error"}")
        return false
      end

      normal, economy = %w[normal economy].map { |mode| reports.find { |report| report.route.mode == mode } }
      gate = EconomyGate.new(cases:, results: economy.results, route: economy.route, run: economy.scorecard_run) if economy
      column = Scorecard::Economy.new(results: economy.results, model: economy.route.model, effort: economy.route.effort, allowed: gate.allowed?) if gate
      if gate
        gate.write(@economy_gate_path)
        @out.puts("Economy gate: #{@economy_gate_path} rewritten: the economy model #{gate.allowed? ? "may" : "may not"} serve (ADR-0003)")
      end
      File.atomic_write(@scorecard_path.to_s) { |file| file.write(Scorecard.new(cases:, results: normal.results, run: normal.scorecard_run, economy: column).render) }
      @out.puts("Scorecard: #{@scorecard_path} rewritten")
      true
    end

    # A failed case shows its last failed attempt: with --repeat the last
    # attempt may have passed (review finding C3 of pull request #39).
    def outcome(result)
      status = { pass: "pass", fail: "FAIL", error: "ERROR" }.fetch(result.status)
      shown = result.status == :fail ? result.attempts.reverse.find { |attempt| attempt.status == :fail } : result.attempts.last
      note = case result.status
      when :error then shown.error
      when :fail then failing(shown)
      else "unstable: #{result.attempts.count { |attempt| attempt.status == :fail }} of #{result.attempts.count { |attempt| attempt.status != :error }} failed" if result.unstable
      end
      line(result.kase, status, [ note, (unusual(shown) unless result.status == :error) ].compact_blank.join("; "))
    end

    # The last turn's outcome when it was not a reply, a command or a
    # deletion: the visitor got a fixed text (NFR-03, SR-19), whatever the
    # checks said.
    def unusual(attempt)
      outcome = attempt.run&.turns&.last&.outcome
      "outcome #{outcome}" unless outcome.nil? || Report::ANSWERED.include?(outcome)
    end

    def failing(attempt)
      notes = Array(attempt.checks).select(&:failed?).map { |check| "#{check.key}: #{check.detail}" }
      notes << "rubric: #{attempt.verdict.reason}" if attempt.verdict && !attempt.verdict.pass
      notes.join("; ")
    end

    def line(kase, status, note) = format("%-38s %-12s %-6s %s", kase.id, kase.suite, status, note).rstrip

    def phrases = YAML.safe_load_file(Rails.root.join("evals/phrases.yml"))

    def commit = git("rev-parse", "--short", "HEAD").to_s.strip.presence || "unknown"

    # The tree's changes, as git status lists them, nil when git could not
    # read the tree. The scorecard, the gate and the recordings are a run's
    # output, not its input. A file git does not track yet changes the tree
    # too (a new locale file or initializer is loaded by the run), as
    # bin/deploy counts it (review finding V1 of pull request #55).
    def changes
      git("status", "--porcelain", "--untracked-files=all")&.lines&.map(&:chomp)&.reject { |line| output?(line) }
    end

    # A line of git status's that names a run's output alone: a rename or a
    # copy names two paths ("old -> new"), both of which must be, and a path
    # with unusual characters comes quoted (the fix review of #66, R4).
    def output?(line)
      line[3..].to_s.split(" -> ").map { |path| path.delete_prefix('"').delete_suffix('"') }.all? do |path|
        %w[evals/scorecard.md evals/economy_allowed.yml].include?(path) || path.start_with?("evals/recordings/")
      end
    end

    # A tree git could not read counts as changed.
    def dirty? = changes.nil? || changes.any?

    def git(*args) = @git.call(*args)
  end
end

require_relative "report"
