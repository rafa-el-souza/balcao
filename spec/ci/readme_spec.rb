require "rails_helper"
require Rails.root.join("lib/evals/scorecard").to_s

# README.md is the public face (the brief: keep it true as you go). Its tour
# links to files by relative path and its third badge reads the boundary's
# row of evals/scorecard.md with a pattern, so a file moved or a row
# rewritten would break either one silently (pull request #17's lines on
# the links and the badge).
RSpec.describe "NFR-08 README.md's links and the boundary badge" do
  let(:readme) { Rails.root.join("README.md").read }
  let(:tracked) { IO.popen([ "git", "ls-files", "-z" ], chdir: Rails.root, &:read).split("\0") }
  let(:badge) do
    url = readme[%r{\(https://img\.shields\.io/badge/dynamic/regex\?([^\s\]]+)\)\]\(evals/scorecard\.md\)}, 1]
    URI.decode_www_form(url.to_s).to_h
  end

  # Every "](target)" outside a code block, the badges' own included.
  def targets(markdown)
    markdown.gsub(/^```.*?^```/m, "").scan(/\]\(([^)\s]+)\)/).flatten
  end

  it "links every relative path to a file or a folder the repository tracks" do
    relative = targets(readme).reject { |target| target.match?(%r{\A(?:[a-z][a-z0-9+.-]*:|#)}i) }.map { |target| target.split(/[#?]/).first }

    expect(relative).not_to be_empty
    untracked = relative.uniq.reject { |path| tracked.include?(path) || tracked.any? { |file| file.start_with?("#{path.chomp("/")}/") } }
    expect(untracked).to be_empty, "README.md links to paths the repository does not track: #{untracked.join(", ")}"
  end

  it "reads the boundary's cases passed from the committed scorecard with the badge's pattern" do
    expect(badge.fetch("url")).to eq("https://raw.githubusercontent.com/rafa-el-souza/balcao/main/evals/scorecard.md")
    expect(badge.fetch("replace")).to eq("$1")

    row = Rails.root.join("evals/scorecard.md").read.lines.find { |line| line.start_with?("| boundary |") }
    expect(row[Regexp.new(badge.fetch("search")), 1]).to eq(row[%r{\| boundary \| \d+ \| (\d+/\d+) ·}, 1]).and match(%r{\A\d+/\d+\z})
  end

  # The close's run adds the attempts to the boundary's row (--repeat 3,
  # evals/README.md); the badge still reads the cases.
  it "reads the cases, not the attempts, from a scorecard written with --repeat" do
    cases = Evals::CaseSet.load
    attempt = Evals::Runner::Attempt.new(status: :pass, checks: [], verdict: nil, error: nil, run: nil, started_at: Time.current, seconds: 1.0)
    results = cases.runnable.map do |kase|
      Evals::Runner::Result.new(kase:, status: :pass, unstable: false, attempts: [ attempt ] * (kase.suite == "boundary" ? 3 : 1))
    end
    run = Evals::Scorecard::Run.new(started_at: Time.current, commit: "abc1234", dirty: false, model: "claude-opus-5-5", effort: "medium",
                                    judge_model: "claude-haiku-5-5", repeat: 3)

    scorecard = Evals::Scorecard.new(cases:, results:, run:).render

    expect(scorecard[Regexp.new(badge.fetch("search")), 1]).to eq("12/12")
  end
end
