require "optparse"
require_relative "scorecard"

# bin/evals' command line (evals/README.md, Running). It reads and checks
# every case first, selects some, and either lists them or runs them live on
# the normal model through the app's pipeline (Evals::Pipeline), the rubrics
# judged by the economy model once it has failed its known-bad replies. It
# prints each case as it ends and a table per suite, writes every attempt
# whole to evals/results/ (gitignored: replies, checks, verdicts, spans and
# tokens), and with --all --scorecard rewrites evals/scorecard.md, unless a
# case ended in error, since the run then measured less than the scorecard
# would say.
#
# Exit status: 0 when every case run passed, 1 when one failed or ended in
# error or the run stopped, 2 for a command it does not take. The economy
# model's run arrives at M2; recording and replaying the fast subset at M3.
module Evals
  class CLI
    BANNER = "Usage: bin/evals (--all | --suite NAME... | --case ID...) [--model normal] [--scorecard] [--list]".freeze
    LATER = {
      "--both-models" => "the economy model's run arrives at M2", "--record" => "recording arrives at M3",
      "--recorded" => "replaying recordings arrives at M3", "--fast" => "the fast subset's recordings arrive at M3"
    }.freeze

    class Usage < StandardError; end

    def initialize(argv, out: $stdout, err: $stderr, env: ENV, cases_path: CaseSet::PATH,
                   results_dir: Rails.root.join("evals/results"), scorecard_path: Scorecard::PATH, pause: ->(seconds) { sleep(seconds) })
      @argv = argv
      @out = out
      @err = err
      @env = env
      @cases_path = cases_path
      @results_dir = Pathname(results_dir)
      @scorecard_path = Pathname(scorecard_path)
      @pause = pause
    end

    def run
      options = parse
      return help if options[:help]

      cases = CaseSet.load(@cases_path)
      selected = select(cases, options)
      return list(selected) if options[:list]
      raise Usage, "ANTHROPIC_API_KEY is blank: a live run needs the dev/eval key in the environment" if @env["ANTHROPIC_API_KEY"].to_s.strip.empty?

      live(cases, selected, scorecard: options[:scorecard])
    rescue Usage, OptionParser::ParseError => e
      @err.puts("bin/evals: #{e.message}", BANNER)
      2
    rescue CaseSet::Invalid => e
      @err.puts("bin/evals: #{e.message}")
      1
    end

    private

    def parse
      options = { suites: [], ids: [], model: "normal" }
      parser = OptionParser.new do |opts|
        opts.banner = BANNER
        opts.on("--all", "Every case of a delivered milestone (#{RUNNABLE_MILESTONES.join(", ")})") { options[:all] = true }
        opts.on("--suite NAME", "A suite's cases of a delivered milestone; repeatable") { |name| options[:suites] << name }
        opts.on("--case ID", "One case, whatever its milestone; repeatable") { |id| options[:ids] << id }
        opts.on("--model MODEL", "normal; the economy model's run arrives at M2") { |model| options[:model] = model }
        opts.on("--scorecard", "With --all: rewrite evals/scorecard.md") { options[:scorecard] = true }
        opts.on("--list", "List the selected cases and stop: no key, no model call") { options[:list] = true }
        LATER.each_key { |flag| opts.on(flag) { options[:later] = flag } }
        opts.on("-h", "--help") { options[:help] = parser }
      end
      parser.parse(@argv)
      check(options)
    end

    def check(options)
      raise Usage, "#{options[:later]}: #{LATER.fetch(options[:later])}" if options[:later]
      raise Usage, "--model #{options[:model]}: only normal runs until the economy model's run arrives at M2" unless options[:model] == "normal"

      kinds = [ options[:all], options[:suites].any?, options[:ids].any? ].count(&:itself)
      raise Usage, "choose one of --all, --suite or --case" unless kinds == 1 || options[:help]
      raise Usage, "--scorecard rewrites the scorecard from --all alone" if options[:scorecard] && !options[:all]
      raise Usage, "--scorecard and --list do not go together" if options[:scorecard] && options[:list]

      options
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

    def list(selected)
      selected.each { |kase| @out.puts(line(kase, kase.milestone, "#{kase.messages.size} message(s)#{", rubric" if kase.rubric}")) }
      @out.puts("#{selected.size} #{"case".pluralize(selected.size)}")
      0
    end

    def live(cases, selected, scorecard:)
      ActiveRecord::Migration.maintain_test_schema!
      route = ModelPolicy.route("normal")
      judge = Judge.new(client: AgentRunner.default_client)
      report = Report.new(argv: @argv, route:, judge:, started_at: Time.current, commit: commit, dirty: dirty?)
      @out.puts("bin/evals: #{selected.size} #{"case".pluralize(selected.size)} on #{route.model} (effort #{route.effort}), judged by #{judge.model}")

      begin
        report.preflight = judge.preflight! if selected.any?(&:rubric)
        @out.puts("judge: failed the #{Judge::KNOWN_BAD.size} known-bad replies, as it must") if report.preflight
        runner = Runner.new(pipeline: Pipeline.new, checks: Checks.new(phrases:), judge:, route:, pause: @pause)
        runner.call(selected) do |result|
          report.results << result
          @out.puts(outcome(result))
        end
      rescue Judge::Error, Runner::Fatal, Anthropic::Errors::APIError => e
        report.stopped = "#{e.class}: #{e.message}"
        @err.puts("bin/evals: the run stopped: #{report.stopped}")
      end
      finish(report, cases, scorecard:)
    end

    def finish(report, cases, scorecard:)
      report.finished_at = Time.current
      @out.puts("", *report.summary)
      @out.puts("Results: #{report.write(@results_dir)}")
      written = scorecard && write_scorecard(report, cases)
      ok = report.stopped.nil? && report.results.all? { |result| result.status == :pass }
      @out.puts("Scorecard: #{@scorecard_path} rewritten") if written
      ok ? 0 : 1
    end

    def write_scorecard(report, cases)
      errored = report.results.select { |result| result.status == :error }.map { |result| result.kase.id }
      if report.stopped || errored.any?
        @err.puts("bin/evals: scorecard not written: #{report.stopped ? "the run stopped" : "#{errored.join(", ")} ended in error"}")
        return false
      end

      @scorecard_path.write(Scorecard.new(cases:, results: report.results, run: report.scorecard_run).render)
      true
    end

    def outcome(result)
      status = { pass: "pass", fail: "FAIL", error: "ERROR" }.fetch(result.status)
      last = result.attempts.last
      note = case result.status
      when :error then last.error
      when :fail then failing(last)
      else "unstable: #{result.attempts.count { |attempt| attempt.status == :fail }} of #{result.attempts.count { |attempt| attempt.status != :error }} failed" if result.unstable
      end
      line(result.kase, status, [ note, (unusual(last) unless result.status == :error) ].compact_blank.join("; "))
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

    # The scorecard is the run's output, not its input.
    def dirty?
      git("status", "--porcelain", "--untracked-files=no").lines.map(&:chomp).reject { |line| line.end_with?(" evals/scorecard.md") }.any?
    end

    def git(*args) = IO.popen([ "git", *args ], chdir: Rails.root, err: File::NULL, &:read).to_s
  end
end

require_relative "report"
