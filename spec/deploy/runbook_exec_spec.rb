require "rails_helper"

# Threat model SR-24 (review findings C2 and A1 of pull request #65): the
# database owner's password stays in each app container's configuration,
# which the web container's entrypoint needs for its migrations and the app
# role's grants, and which `kamal app exec --reuse`, a `docker exec` into
# the running container, hands whole to the command it runs, where a process
# of the app's own user can read it. A command run in a new container goes
# through the entrypoint, which takes the password out first
# (bin/docker-entrypoint), so the runbook runs every app command that way.
RSpec.describe "SR-24 the runbook runs every app command in a new container" do
  # The runbook, and every command a task or a document of the repository
  # hands the operator (the fix review's sister on pull request #65: a task's
  # comment still gave `--reuse`); the review records keep the commands they
  # quoted.
  let(:texts) do
    Rails.root.glob("{docs/*.md,lib/tasks/*.rake,README.md}").to_h { |path| [ path.relative_path_from(Rails.root).to_s, path.read ] }
  end

  it "never runs an app command inside the running container" do
    commands = texts.flat_map { |path, text| text.scan(/kamal app exec[^`\n]*/).map { |command| "#{path}: #{command}" } }

    expect(commands.grep(/docs\/runbook\.md/)).not_to be_empty
    expect(commands.grep(/--reuse/)).to be_empty
  end
end
