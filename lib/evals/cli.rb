require "optparse"
require_relative "scorecard"
require_relative "economy_gate"

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
# Exit status: 0 when every case run passed, 1 when one failed or ended in
# error or the run stopped, 2 for a command it does not take. Recording and
# replaying the fast subset arrive at M3.
module Evals
  class CLI
    BANNER = "Usage: bin/evals (--all | --suite NAME... | --case ID...) [--model normal|economy | --both-models] [--repeat N] " \
             "[--scorecard] [--list]".freeze
    MODES = ModelPolicy::ROUTES.keys.freeze
    LATER = {
      "--record" => "recording arrives at M3", "--recorded" => "replaying recordings arrives at M3",
      "--fast" => "the fast subset's recordings arrive at M3"
    }.freeze

    class Usage < StandardError; end

    def initialize(argv, out: $stdout, err: $stderr, env: ENV, cases_path: CaseSet::PATH,
                   results_dir: Rails.root.join("evals/results"), scorecard_path: Scorecard::PATH,
                   economy_gate_path: EconomyGate::PATH, pause: ->(seconds) { sleep(seconds) })
      @argv = argv
      @out = out
      @err = err
      @env = env
      @cases_path = cases_path
      @results_dir = Pathname(results_dir)
      @scorecard_path = Pathname(scorecard_path)
      @economy_gate_path = Pathname(economy_gate_path)
      @pause = pause
    end

    def run
      options = parse
      return help if options[:help]

      cases = CaseSet.load(@cases_path)
      selected = select(cases, options)
      repeated!(selected, options[:repeat])
      return list(selected, options[:repeat]) if options[:list]
      raise Usage, "ANTHROPIC_API_KEY is blank: a live run needs the dev/eval key in the environment" if @env["ANTHROPIC_API_KEY"].to_s.strip.empty?

      live(cases, selected, scorecard: options[:scorecard], repeat: options[:repeat], modes: options[:modes])
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
        opts.on("--all", "Every case of a delivered milestone (#{RUNNABLE_MILESTONES.join(", ")})") { options[:all] = true }
        opts.on("--suite NAME", "A suite's cases of a delivered milestone; repeatable") { |name| options[:suites] << name }
        opts.on("--case ID", "One case, whatever its milestone; repeatable") { |id| options[:ids] << id }
        opts.on("--model MODEL", "#{MODES.join(" or ")} (normal when left out)") { |model| options[:model] = model }
        opts.on("--both-models", "Every selected case on the normal model, then on the economy model") { options[:both] = true }
        opts.on("--repeat N", Integer, "Each #{Runner::REPEATED_SUITES.join(", ")} case N times (#{Runner::REPEAT.min} to #{Runner::REPEAT.max}), every attempt graded") do |count|
          options[:repeat] = count
        end
        opts.on("--scorecard", "With --all: rewrite evals/scorecard.md") { options[:scorecard] = true }
        opts.on("--list", "List the selected cases and stop: no key, no model call") { options[:list] = true }
        LATER.each_key { |flag| opts.on(flag) { options[:later] = flag } }
        opts.on("-h", "--help") { options[:help] = parser }
      end
      stray = parser.parse(@argv)
      raise Usage, "#{stray.join(" ")}: not an option's value; each case and suite takes its own --case or --suite" if stray.any?

      check(options)
    end

    def check(options)
      raise Usage, "#{options[:later]}: #{LATER.fetch(options[:later])}" if options[:later]
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

      kinds = [ options[:all], options[:suites].any?, options[:ids].any? ].count(&:itself)
      raise Usage, "choose one of --all, --suite or --case" unless kinds == 1 || options[:help]
      raise Usage, "--scorecard rewrites the scorecard from --all alone" if options[:scorecard] && !options[:all]
      raise Usage, "--scorecard and --list do not go together" if options[:scorecard] && options[:list]
      if options[:repeat] && !Runner::REPEAT.cover?(options[:repeat])
        raise Usage, "--repeat #{options[:repeat]}: it takes #{Runner::REPEAT.min} to #{Runner::REPEAT.max}: with fewer one failure " \
                     "leaves a single pass, and more costs what a typo would"
      end

      options
    end

    # --repeat applies to the boundary suite (README, Flakiness policy), so a
    # selection with none of its cases would repeat nothing.
    def repeated!(selected, repeat)
      return if repeat.nil? || selected.any? { |kase| Runner::REPEATED_SUITES.include?(kase.suite) }

      raise Usage, "--repeat applies to the #{Runner::REPEATED_SUITES.join(", ")} suite, and the selection has no case of it"
    end

    def help
      @out.puts(BANNER)
      0
    end

    def select(cases, options)
      return cases.runnable if options[:all]

      if options[:ids].any?
        missing = options[:ids].reject { |id| cases.find(id) }
        raise Usage, "no case #{missing.join(", ")} in #{@cases_path}" if missing.any?

        return options[:ids].uniq.map { |id| cases.find(id) }
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
    def live(cases, selected, scorecard:, repeat:, modes:)
      ActiveRecord::Migration.maintain_test_schema!
      judge = Judge.new(client: AgentRunner.default_client)
      reports = []
      modes.each do |mode|
        route = ModelPolicy.route(mode)
        report = Report.new(argv: @argv, route:, judge:, started_at: Time.current, commit: commit, dirty: dirty?, repeat:)
        reports << report
        @out.puts("bin/evals: #{selected.size} #{"case".pluralize(selected.size)} on #{route.model} (effort #{route.effort}), " \
                  "judged by #{judge.model}#{", each #{Runner::REPEATED_SUITES.join(", ")} case #{repeat} times" if repeat}")
        break unless run_on(report, judge, selected, route, repeat:, first: reports.one?)
      rescue Interrupt, StandardError
        # What ran is written before the interruption or the bug goes on.
        finish(reports, cases, scorecard: false)
        raise
      end
      finish(reports, cases, scorecard:)
    end

    # Runs the selection on one route; false when the run stopped.
    def run_on(report, judge, selected, route, repeat:, first:)
      if first && selected.any?(&:rubric)
        report.preflight = preflight(judge)
        @out.puts("judge: failed the #{Judge::KNOWN_BAD.size} known-bad replies, as it must")
      end
      runner = Runner.new(pipeline: Pipeline.new(mode: route.mode), checks: Checks.new(phrases:), judge:, route:, repeat:, pause: @pause)
      runner.call(selected) do |result|
        report.results << result
        @out.puts(outcome(result))
      end
      true
    rescue Judge::Unfit, Judge::Error, Runner::Fatal, Anthropic::Errors::APIError => e
      stopped(report, e)
      false
    rescue Interrupt, StandardError => e
      stopped(report, e)
      raise
    ensure
      report.finished_at = Time.current
    end

    # The case under way when the run stopped, with its attempts (review
    # finding C3 of pull request #20).
    def stopped(report, error)
      if error.is_a?(Runner::Fatal) && error.result
        report.results << error.result
        @out.puts(outcome(error.result))
      end
      report.stopped = "#{error.class}: #{error.message}"
      @err.puts("bin/evals: the run stopped: #{report.stopped}")
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

    def finish(reports, cases, scorecard:)
      reports.each do |report|
        @out.puts("", ("On the #{report.route.mode} model, #{report.route.model}:" if reports.many?), *report.summary)
        @out.puts("Results: #{report.write(@results_dir)}")
      end
      write_scorecard(reports, cases) if scorecard
      ok = reports.all? { |report| report.stopped.nil? && report.results.all? { |result| result.status == :pass } }
      ok ? 0 : 1
    end

    # The scorecard from the normal model's report, with the economy model's
    # column and ADR-0003's gate when the run had both (EconomyGate).
    def write_scorecard(reports, cases)
      errored = reports.flat_map(&:results).select { |result| result.status == :error }.map { |result| result.kase.id }.uniq
      if reports.any?(&:stopped) || errored.any?
        @err.puts("bin/evals: scorecard not written: #{reports.any?(&:stopped) ? "the run stopped" : "#{errored.join(", ")} ended in error"}")
        return false
      end

      normal, economy = %w[normal economy].map { |mode| reports.find { |report| report.route.mode == mode } }
      gate = EconomyGate.new(cases:, results: economy.results, route: economy.route, run: economy.scorecard_run) if economy
      column = Scorecard::Economy.new(results: economy.results, model: economy.route.model, effort: economy.route.effort, allowed: gate.allowed?) if gate
      @scorecard_path.write(Scorecard.new(cases:, results: normal.results, run: normal.scorecard_run, economy: column).render)
      @out.puts("Scorecard: #{@scorecard_path} rewritten")
      return true unless gate

      gate.write(@economy_gate_path)
      @out.puts("Economy gate: #{@economy_gate_path} rewritten: the economy model #{gate.allowed? ? "may" : "may not"} serve (ADR-0003)")
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

    def commit = git("rev-parse", "--short", "HEAD").strip.presence || "unknown"

    # The scorecard and the gate are the run's output, not its input.
    def dirty?
      git("status", "--porcelain", "--untracked-files=no").lines.map(&:chomp)
                                                          .reject { |line| line.end_with?(" evals/scorecard.md", " evals/economy_allowed.yml") }.any?
    end

    def git(*args) = IO.popen([ "git", *args ], chdir: Rails.root, err: File::NULL, &:read).to_s
  end
end

require_relative "report"
