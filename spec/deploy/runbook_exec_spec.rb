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
  let(:runbook) { Rails.root.join("docs/runbook.md").read }

  it "never runs an app command inside the running container" do
    commands = runbook.scan(/kamal app exec[^`\n]*/)

    expect(commands).not_to be_empty
    expect(commands.grep(/--reuse/)).to be_empty
  end
end
