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
                                  "web/package-lock.json", "Gemfile", "Gemfile.lock", ".tool-versions",
                                  "':(glob)**/mise.*'", "':(glob)**/.mise.*'",
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

  # The fix review's R3: "deploy at once" after the owner's new password
  # cannot hold when the checklist's first steps stop the deploy, and the
  # database and the running containers then disagree for as long.
  it "sets the database owner's new password in production only once the checklist's steps that can stop it have passed" do
    row = runbook.lines.find { |line| line.start_with?("| `POSTGRES_PASSWORD`") }

    expect(row).to include("between the operator's checklist's steps 4 and 5")
  end

  # The fix review's R4: the MVP host's two heartbeats were paused at the
  # cut's first step, days maybe before it stops serving the demo; only its
  # Telegram watch fails, and only from the token's rotation.
  it "keeps the MVP host's canary heartbeat on while it serves, pausing its Telegram one at the token's rotation" do
    cut = section("The production cut (M3-7)")
    step1 = cut[cut.index("1. *Owner:*")...cut.index("2. *Owner:*")].squish

    expect(step1).not_to include("paused in the console at the same time")
    expect(step1).to include("Telegram heartbeat paused in the console right before the token's rotation")
  end

  # The fix review's R5: the cut's step 2 runs the host checklist on a
  # firewall that admits 22 alone until step 5, and the checklist asked for
  # 80 and 443 too, which only opening them early, C6's failure, would pass.
  it "runs at the cut's step 2 a host checklist its closed firewall can pass" do
    host = section("Host checklist (SR-24)")
    outside = host[host.index("From outside:")..].squish

    expect(outside).to include("TCP 22 and ICMP alone until the cut's step 5")
  end

  # The fix review's R6: the guard leaves a file that exists at its mode,
  # so one made earlier at 644 took the secrets at 644.
  it "narrows an existing env file to mode 600 before a secret is written to it" do
    chmod = account.index("chmod 600 <the file>")

    expect(chmod).not_to be_nil
    expect(chmod).to be > account.index("install -m 600 /dev/null <the file>")
    expect(chmod).to be < account.index(">> <the file>")
  end

  # The fix review's R7: an SSH login with a password, on the network the
  # development VM shares, is a door the agent can knock on.
  it "puts the operator's VM on a network of its own, its SSH taking keys alone" do
    expect(account.squish).to include("a virtual network of its own", "`PasswordAuthentication no`")
  end

  # The fix review's note on pull request #67: the rotation sent production
  # to the operator account's line, which appends all eight generated
  # values, so one rotation would have rotated the encryption keys, the
  # pepper and the owner's password with it.
  it "rotates one production secret with a value made for it alone" do
    rotation = section("Rotating a secret").squish

    expect(rotation).to include("ruby -rsecurerandom -e 'puts SecureRandom.alphanumeric(<its length>)'")
    expect(rotation).not_to include("from the operator's Ruby line in production")
  end

  # The production cut (M3-7): the production key has a passphrase, derived
  # in a hundred rounds, held for a deploy session by an agent of its own for
  # an hour at most, killed at the session's end, so no unlocked key outlives
  # the session in the VM.
  it "holds the production key in an agent of the session's own, for an hour at most, killed at its end" do
    expect(account.squish).to include("with a long passphrase", "`ssh-keygen -t ed25519 -a 100 -C balcao-prod -f ~/.ssh/balcao-prod`")
    expect(checklist).to include('eval "$(ssh-agent -s)" >/dev/null && ssh-add -t 1h ~/.ssh/balcao-prod')
    expect(checklist).to include("`ssh-agent -k`")
  end

  # The production cut (M3-7): the operator's chat is linked by a Start that
  # reaches the host through the bot's webhook, so linking production's
  # before the bot's task points the webhook at it sends the Start to the MVP
  # host, or to a refusal.
  it "links production's operator chat only after the bot's task points the webhook at it" do
    cut = section("The production cut (M3-7)").squish
    task = cut.index("the bot's task in production")
    link = cut.index("the operator's chat linked again")

    expect(task).not_to be_nil
    expect(link).not_to be_nil
    expect(link).to be > task
  end

  # The production cut (M3-7): the reserved IP is protected against deletion,
  # and the provider deletes no server holding a protected primary IP, which
  # leaves a server only while it is off (#68's session, read on the
  # provider's FAQ; done at the cut's step 9).
  it "deletes a rehearsal host only after powering it off and taking the reserved IP off it" do
    delete = section("Rehearsal hosts (from M3): the per-slice flow").squish
    steps = [ "hcloud server poweroff ensaio", "hcloud primary-ip unassign ensaio", "hcloud server delete ensaio" ].map { |line| delete.index(line) }

    expect(steps).to all(be_an(Integer))
    expect(steps).to eq steps.sort
  end
end
