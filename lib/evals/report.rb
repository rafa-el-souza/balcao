# One run of bin/evals as the person running it reads it and as the results
# file keeps it (evals/README.md, Running): the table per suite with the 95%
# Wilson interval, the tokens per model from the API's own usage (the
# attendant's from each turn's spans, the judge's from its responses) and
# their dollars at config/prices.yml's prices (FR-14), and every attempt
# whole: the messages and replies, the outcome of each turn, its model and
# tool calls, each check with its detail and the judge's verdict. The file is
# evals/results/<UTC time>-<commit>.json, gitignored, with -economy before
# the extension for a run on the economy model.
module Evals
  class Report
    # The outcomes of a turn the visitor got an answer from.
    ANSWERED = %w[replied command deleted].freeze
    # The judge's usage is kept apart from the attendant's, under its model,
    # and so is the guardrail's (FR-20).
    JUDGE = " (judge)".freeze
    GUARDRAIL = " (guardrail)".freeze
    APART = / \((?:judge|guardrail)\)\z/

    attr_accessor :preflight, :stopped, :finished_at
    attr_reader :results, :started_at, :route

    def initialize(argv:, route:, judge:, started_at:, commit:, dirty:, repeat: nil)
      @argv = argv
      @route = route
      @judge = judge
      @started_at = started_at
      @commit = commit
      @dirty = dirty
      @repeat = repeat
      @results = []
      @clock = AgentRunner::MONOTONIC.call
    end

    def scorecard_run
      Scorecard::Run.new(started_at:, commit: @commit, dirty: @dirty, model: @route.model, effort: @route.effort, judge_model: @judge.model,
                         repeat: @repeat)
    end

    def summary
      [ format("%-12s %5s %6s %6s %9s %8s", "Suite", "Cases", "Passed", "Score", "95%", "Unstable"),
        *@results.group_by { |result| result.kase.suite }.map { |suite, results| suite_line(suite, results) },
        attempts, totals, outcomes, guardrail, tokens, dollars ].compact
    end

    def write(dir)
      dir.mkpath
      path = dir.join("#{started_at.utc.strftime("%Y%m%dT%H%M%SZ")}-#{@commit}#{"-dirty" if @dirty}#{"-#{@route.mode}" unless @route.mode == "normal"}.json")
      path.write(JSON.pretty_generate(to_h))
      path
    end

    def to_h
      { run: { started_at: started_at.utc.iso8601, finished_at: finished_at&.utc&.iso8601, command: [ "bin/evals", *@argv ].join(" "),
               commit: @commit, dirty: @dirty, model: @route.model, effort: @route.effort, judge_model: @judge.model, repeat: @repeat,
               stopped: },
        judge_preflight: preflight&.map(&:to_h), usage: usage, cost_usd: cost_usd.transform_values { |usd| usd.round(6).to_f },
        cases: @results.map { |result| case_h(result) } }
    end

    # The dollars of each model's tokens at config/prices.yml's prices
    # (FR-14), unrounded: the input billed at the input price is the input
    # less the cache read and written, which have prices of their own (the
    # eval audit's finding 8).
    def cost_usd
      usage.to_h do |model, use|
        billed = AgentRunner::Usage.new(model: model.sub(APART, ""), output_tokens: use[:output_tokens],
                                        input_tokens: use[:input_tokens] - use[:cache_read_tokens] - use[:cache_write_tokens],
                                        cache_creation_tokens: use[:cache_write_tokens], cached_tokens: use[:cache_read_tokens])
        [ model, Prices.cost_usd(billed) ]
      end
    end

    private

    def suite_line(suite, results)
      passed = results.count { |result| result.status == :pass }
      graded = results.count { |result| result.status != :error }
      low, high = Scorecard.wilson(passed, graded).map { |bound| (bound * 100).round }
      score = graded.zero? ? "—" : "#{(passed * 100.0 / graded).round}%"
      format("%-12s %5d %6d %6s %9s %8d", suite, results.size, passed, score, "#{low}–#{high}%", results.count(&:unstable))
    end

    # With --repeat, the attempts of each repeated suite passed out of those
    # graded, with their 95% Wilson interval (README, Flakiness policy),
    # which counts them as independent though one case's attempts share its
    # question (review finding C4 of pull request #39).
    def attempts
      repeated = @results.select { |result| @repeat && Runner::REPEATED_SUITES.include?(result.kase.suite) }.group_by { |result| result.kase.suite }
      lines = repeated.map do |suite, results|
        passed, graded = Scorecard.attempts(results)
        low, high = Scorecard.wilson(passed, graded).map { |bound| (bound * 100).round }
        "#{suite} #{passed}/#{graded} passed (#{low}–#{high}% as if independent), each case #{@repeat} times"
      end
      "Attempts: #{lines.join("; ")}" if lines.any?
    end

    def totals
      counts = @results.group_by(&:status).transform_values(&:size)
      attempts = @results.sum { |result| result.attempts.size }
      seconds = (AgentRunner::MONOTONIC.call - @clock).round
      "#{@results.size} #{"case".pluralize(@results.size)}: #{counts.fetch(:pass, 0)} passed (#{@results.count(&:unstable)} unstable), " \
        "#{counts.fetch(:fail, 0)} failed, #{counts.fetch(:error, 0)} in error · #{attempts} #{"attempt".pluralize(attempts)} · #{seconds / 60}m#{seconds % 60}s"
    end

    # The turns of graded attempts that did not end in an answer: cut off,
    # refused, past the tool limit, answered from stored reservations.
    def outcomes
      turns = @results.flat_map(&:attempts).reject { |attempt| attempt.status == :error }.filter_map(&:run).flat_map(&:turns)
      unusual = turns.map(&:outcome).reject { |outcome| ANSWERED.include?(outcome) }.tally
      "Outcomes: #{unusual.map { |outcome, count| "#{count} #{outcome}" }.join(", ")}" if unusual.any?
    end

    # FR-20: the checks of every attempt's replies, an errored attempt's too,
    # since a check without a verdict makes its attempt an error (Runner,
    # the fix review's R1 on pull request #54): how many replaced a reply or
    # gave no verdict, and the time of those that gave one, at the median and
    # at p95 (FR-20's figure).
    def guardrail
      checks = @results.flat_map(&:attempts).filter_map(&:run).flat_map(&:turns).filter_map(&:guardrail)
      return if checks.empty?

      times = checks.reject(&:error_type).filter_map(&:latency_ms).sort
      time = "; time of the #{times.size} #{"verdict".pluralize(times.size)}: median #{seconds(percentile(times, 0.5))}, " \
             "p95 #{seconds(percentile(times, 0.95))}" if times.any?
      "Guardrail: #{checks.size} #{"check".pluralize(checks.size)}, #{checks.count { |check| check.clinical == true }} replaced, " \
        "#{checks.count(&:error_type)} without a verdict#{time}"
    end

    # The nearest rank, so a figure is one that was measured.
    def percentile(sorted, share) = sorted[((sorted.size * share).ceil - 1).clamp(0, sorted.size - 1)]

    def seconds(milliseconds) = format("%.1f s", milliseconds / 1000.0)

    def tokens
      lines = usage.map do |model, use|
        "#{model} #{use[:input_tokens].to_fs(:delimited, locale: :en)} in (#{use[:cache_read_tokens].to_fs(:delimited, locale: :en)} cache read, " \
          "#{use[:cache_write_tokens].to_fs(:delimited, locale: :en)} written), #{use[:output_tokens].to_fs(:delimited, locale: :en)} out"
      end
      "Tokens: #{lines.join("; ")}" if lines.any?
    end

    # The attendant's models first, then the guardrail's and the judge's
    # apart; a model the table has no row for is priced at its highest prices
    # (Prices), and said.
    def dollars
      order = ->(model) { model.end_with?(JUDGE) ? 2 : model.end_with?(GUARDRAIL) ? 1 : 0 }
      costs = cost_usd.sort_by { |model, _| [ order.call(model), model ] }.map do |model, usd|
        "#{model} US$ #{format("%.4f", usd)}#{" (no row in the table: its highest prices)" unless Prices.models.include?(model.sub(APART, ""))}"
      end
      "Dollars at config/prices.yml's prices of #{Prices.verified_on.iso8601}: #{costs.join("; ")}" if costs.any?
    end

    # Per model: the attendant's input counts the cache read and written, as
    # the trace does (TurnTrace); the judge's is the API's input plus the same.
    #
    # A call the refusal fallback served sums its attempts in its span; each
    # attempt is counted at its own model, from the iterations the trace
    # keeps (TurnTrace; review finding C5 of pull request #20).
    def usage
      totals = Hash.new { |hash, model| hash[model] = Hash.new(0) }
      attempts = @results.flat_map(&:attempts)
      attempts.filter_map(&:run).flat_map(&:turns).flat_map(&:model_calls).each do |call|
        if call.iterations.present?
          call.iterations.each do |entry|
            read, written = entry["cached_tokens"].to_i, entry["cache_creation_tokens"].to_i
            add(totals[entry["model"]], input_tokens: entry["input_tokens"].to_i + read + written, output_tokens: entry["output_tokens"],
                                        cache_read_tokens: read, cache_write_tokens: written)
          end
        else
          add(totals[call.model], input_tokens: call.input_tokens, output_tokens: call.output_tokens,
                                  cache_read_tokens: call.cache_read_tokens, cache_write_tokens: call.cache_write_tokens)
        end
      end
      attempts.filter_map(&:run).flat_map(&:turns).filter_map(&:guardrail).each do |check|
        add(totals["#{check.model}#{GUARDRAIL}"], input_tokens: check.input_tokens, output_tokens: check.output_tokens,
                                                  cache_read_tokens: 0, cache_write_tokens: 0)
      end
      (Array(preflight) + attempts.filter_map(&:verdict)).each do |verdict|
        use = verdict.usage
        add(totals["#{verdict.model} (judge)"], **use, input_tokens: use[:input_tokens] + use[:cache_read_tokens] + use[:cache_write_tokens])
      end
      totals.sort.to_h
    end

    def add(total, **counts) = counts.each { |key, value| total[key] += value.to_i }

    def case_h(result)
      { id: result.kase.id, suite: result.kase.suite, lang: result.kase.lang, status: result.status, unstable: result.unstable,
        attempts: result.attempts.map { |attempt| attempt_h(attempt) } }
    end

    def attempt_h(attempt)
      { status: attempt.status, error: attempt.error, started_at: attempt.started_at.utc.iso8601, seconds: attempt.seconds.round(1),
        checks: attempt.checks&.map(&:to_h), judge: attempt.verdict&.to_h,
        turns: attempt.run&.turns&.map do |turn|
          turn.to_h.merge(model_calls: turn.model_calls.map(&:to_h), tool_calls: turn.tool_calls.map(&:to_h), guardrail: turn.guardrail&.to_h)
        end,
        rows: attempt.run&.observation&.to_h&.slice(:reservation_created, :conversation_reset, :data_deleted) }
    end
  end
end
