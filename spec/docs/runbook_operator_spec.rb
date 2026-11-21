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

  # Review finding C2: the review's diff named `.tool-versions` but none of
  # mise's configuration files, which SR-38 names and which can run code in
  # the operator account when mise reads the clone.
  it "reviews every file of the deploy path SR-38 names, mise's configuration files among them" do
    diff = checklist[/^ *git diff "\$\(cat \.last-deployed-sha\)" origin\/main -- (.+)$/, 1]

    expect(diff).not_to be_nil
    expect(diff.split).to include("config/deploy.yml", ".kamal/", "Dockerfile", ".dockerignore", "web/package.json",
                                  "web/package-lock.json", ".tool-versions", "':(glob)**/mise.*'", "':(glob)**/.mise.*'",
                                  "':(glob)**/mise/**'", "':(glob)**/.mise/**'", "':(glob)**/.config/mise*'",
                                  "':(glob)**/.config/mise/**'")
  end

  # The verifier's V2 on pull request #67: "every check reads success" held
  # over a list that lacked a check not created yet. The checklist names the
  # four checks the workflow's jobs make, and a rename of a job must reach it.
  it "reads the CI of origin/main by the names of the workflow's jobs, each one success" do
    jobs = YAML.safe_load_file(Rails.root.join(".github/workflows/ci.yml")).fetch("jobs").values.map { |job| job.fetch("name") }
    listed = checklist.scan(/^ {3}(.+): success$/).flatten

    expect(listed).to eq(jobs.sort)
    expect(checklist).to include("check-runs?per_page=100")
  end

  # Review findings C1 and V1 of pull request #67 and ADR-0023: on one
  # system with the development account, the operator's local registry and
  # Kamal's clone in the shared temporary directory were within the agent's
  # reach. The operator account has a VM of its own; besides, its Kamal
  # clones under a directory of its own, and the checklist reads that the
  # host runs the very image this checkout built.
  it "keeps Kamal's clone out of a shared temporary directory and checks the host runs the image this checkout built" do
    expect(account).to include("a VM of its own", "ADR-0023", "mkdir -m 700 -p ~/.kamal-tmp")
    expect(checklist).to include("export TMPDIR=~/.kamal-tmp")
    expect(checklist).to include("docker image inspect localhost:5556/balcao:$(git rev-parse HEAD) --format '{{.Id}}'")
    expect(checklist.index("export TMPDIR=~/.kamal-tmp")).to be < checklist.index("`kamal deploy`")
    expect(checklist.index("docker image inspect localhost:5556")).to be > checklist.index("`kamal deploy`")
  end

  # The fix review's R1 on pull request #67: a failed deploy leaves the
  # version before it running, so the image check would read a difference
  # and send the owner to stop production and rotate every secret.
  it "reads the host's image against the checkout's only after a deploy that passed" do
    step = checklist[checklist.index("6. The host runs the image")...checklist.index("7. `kamal registry remove`")].squish

    expect(step).to include("only after a deploy that passed")
  end

  # The fix review's R2: production's own heartbeats were named only in the
  # cut, so its env file and its smoke still led to the MVP host's.
  it "names production's own heartbeats where its env file and its smoke read them" do
    expect(account.squish).to include("Balcão produção: canário", "Balcão produção: webhook do Telegram")
    expect(checklist.squish).to include("Balcão produção: canário", "Balcão produção: webhook do Telegram")
  end
end
