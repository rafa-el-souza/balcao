require "rails_helper"

# Threat model SR-37 and SR-38: the operator's account and its checklist for
# a production deploy, as docs/runbook.md writes them for the owner to
# follow (M3-6). The review of pull request #67 found steps that would not
# do what they say; each example holds one.
RSpec.describe "SR-37 SR-38 the operator's account and checklist in the runbook" do
  let(:runbook) { Rails.root.join("docs/runbook.md").read }

  def section(heading) = runbook[/^## #{Regexp.escape(heading)}.*?(?=^## )/m] || raise("no section #{heading}")

  let(:account) { section("The operator account") }
  let(:checklist) { section("A production deploy: the operator's checklist") }

  # Review finding C3: `chmod` before the file existed failed, and the
  # append made it under the umask; a plain `install` would empty a file
  # that holds the secrets already.
  it "creates production's env file for the operator alone before it writes a secret, never emptying one that exists" do
    create = account.index("[ -e <the file> ] || install -m 600 /dev/null <the file>")
    append = account.index(">> <the file>")

    expect(create).not_to be_nil
    expect(append).not_to be_nil
    expect(create).to be < append
    expect(account).to include("stat -c %a <the file>")
  end

  # Review finding C7: Kamal's removal of its local registry leaves the
  # registry's anonymous volume, about 158 MB a deploy, which bin/deploy
  # removes for the rehearsal and nothing removed for production.
  it "removes the local registry's anonymous volume after each production deploy" do
    removal = checklist.index("`kamal registry remove`")
    prune = checklist.index("docker volume prune -f")

    expect(removal).not_to be_nil
    expect(prune).not_to be_nil
    expect(prune).to be > removal
  end
end
