require "rails_helper"

# The image never carries a secret: every value-bearing file the repository
# ignores is ignored by the Docker build context too, and the Dockerfile
# declares no build argument or environment variable with a secret-like name
# (secrets arrive at run time from Kamal). The image also runs as a non-root
# user, on the Ruby and Node versions the repository pins.
RSpec.describe "SR-25 the image carries no secret" do
  let(:dockerfile) { Rails.root.join("Dockerfile").read }
  let(:dockerignore) do
    Rails.root.join(".dockerignore").read.lines(chomp: true).map(&:strip)
      .reject { |line| line.empty? || line.start_with?("#") }
  end

  # The block of .gitignore that starts at its "# Secrets" heading.
  let(:secret_patterns) do
    block = Rails.root.join(".gitignore").read.split(/^# Secrets.*\n/, 2).last.split(/\n\s*\n/, 2).first
    block.lines(chomp: true).reject { |line| line.start_with?("#", "!") || line.strip.empty? }
  end

  it "finds the secret block of .gitignore" do
    expect(secret_patterns).to include(".env", "config/master.key")
  end

  it "ignores every secret pattern of .gitignore at the root and, for bare names, at any depth" do
    secret_patterns.each do |pattern|
      rooted = pattern.delete_prefix("/")
      expect(dockerignore).to include(rooted).or include("/#{rooted}")
      expect(dockerignore).to include("**/#{rooted}") unless pattern.include?("/")
    end
  end

  it "re-includes none of them" do
    negated = dockerignore.select { |line| line.start_with?("!") }.map { |line| line.delete_prefix("!").delete_prefix("/") }

    expect(negated.grep(/env|key|secret|credential/i)).to be_empty
  end

  it "declares no ARG or ENV whose name looks like a secret" do
    instructions = dockerfile.gsub(/\\\n/, " ").scan(/^\s*(?:ARG|ENV)\s+(.+)$/).flatten
    names = instructions.flat_map { |rest| rest.scan(/(?:\A|\s)([A-Za-z_][A-Za-z0-9_]*)(?=[=\s]|\z)/).flatten }

    expect(names).to include("RAILS_ENV", "BOOTSNAP_READONLY")
    expect(names.grep(/SECRET|PASSWORD|PASSWD|TOKEN|KEY|PEPPER|SALT|CREDENTIAL|PRIVATE/i)).to be_empty
  end
end

RSpec.describe "SR-24 the image runs as a non-root user on the pinned toolchain" do
  let(:dockerfile) { Rails.root.join("Dockerfile").read }
  let(:tool_versions) { Rails.root.join(".tool-versions").read.lines.to_h { |line| line.split(" ", 2).map(&:strip) } }

  it "switches to a non-root user in the final stage" do
    final_stage = dockerfile.split(/^FROM\s/).last

    expect(final_stage).to match(/^USER\s+(?!0\b|root\b)\S+/)
  end

  it "builds on the Ruby and Node versions of .tool-versions" do
    expect(dockerfile).to match(%r{^FROM docker\.io/library/ruby:#{Regexp.escape(tool_versions.fetch("ruby"))}-slim@})
    expect(dockerfile).to match(%r{^FROM docker\.io/library/node:#{Regexp.escape(tool_versions.fetch("nodejs"))}-slim@})
  end

  it "pins every base image by digest" do
    expect(dockerfile.scan(/^FROM\s+(\S+)/).flatten.reject { |image| image.match?(/\A[a-z]+\z/) })
      .to all(match(/@sha256:[0-9a-f]{64}\z/))
  end
end
