require "rails_helper"
require "yaml"

# The one host definition (design §8): every rehearsal host and the production
# host are created from ops/cloud-init.yml, with declarative cloud-init modules
# only. The runbook's host checklist verifies the running host; this spec
# keeps the file itself from drifting away from the threat model's list.
RSpec.describe "SR-24 the host definition is declarative and hardened" do
  let(:raw) { Rails.root.join("ops/cloud-init.yml").read }
  let(:config) { YAML.safe_load(raw) }
  let(:files) { config.fetch("write_files").to_h { |file| [ file.fetch("path"), file ] } }

  it "is a cloud-config document" do
    expect(raw.lines.first.chomp).to eq "#cloud-config"
  end

  it "uses no module that runs a script of ours" do
    expect(config.keys & %w[bootcmd scripts-user scripts_user]).to be_empty
    expect(raw).not_to match(/^\s*#!/)
  end

  it "creates the deploy user in the docker group with the key placeholder, and no password login" do
    deploy = config.fetch("users").find { |user| user.is_a?(Hash) && user["name"] == "deploy" }

    expect(Array(deploy.fetch("groups"))).to eq [ "docker" ]
    expect(deploy.fetch("ssh_authorized_keys")).to eq [ "<DEPLOY_PUBLIC_KEY>" ]
    expect(deploy).not_to have_key("sudo")
    expect(deploy.fetch("lock_passwd")).to be true
    expect(config.fetch("ssh_pwauth")).to be false
  end

  it "installs Docker from its own repository, with the signing key inline, and the host's guards" do
    docker = config.dig("apt", "sources").values.find { |source| source["source"].to_s.include?("download.docker.com") }

    expect(docker.fetch("source")).to include("signed-by=$KEY_FILE")
    expect(docker.fetch("key")).to include("BEGIN PGP PUBLIC KEY BLOCK")
    expect(config.fetch("packages")).to contain_exactly(
      "docker-ce", "docker-ce-cli", "containerd.io", "docker-buildx-plugin", "fail2ban", "unattended-upgrades"
    )
  end

  it "writes an sshd drop-in that sorts first, refuses passwords and root, and leaves TCP forwarding on" do
    drop_in = files.fetch("/etc/ssh/sshd_config.d/00-balcao.conf").fetch("content")

    expect(drop_in).to match(/^PasswordAuthentication no$/)
    expect(drop_in).to match(/^PermitRootLogin no$/)
    expect(drop_in).to match(/^KbdInteractiveAuthentication no$/)
    expect(drop_in).not_to match(/^AllowTcpForwarding\s+no/i)
  end

  it "lets deploy run exactly the two runbook checks with sudo, from a 0440 file with no dot in its name" do
    sudoers = files.fetch("/etc/sudoers.d/deploy")
    rules = sudoers.fetch("content").lines(chomp: true).reject { |line| line.strip.empty? || line.start_with?("#") }

    expect(sudoers.fetch("permissions")).to eq "0440"
    expect(rules).to eq [ "deploy ALL=(root) NOPASSWD: /usr/sbin/sshd -T, /usr/bin/fail2ban-client status" ]
  end

  it "runs only list-form commands: the sshd check and the two reloads" do
    expect(config.fetch("runcmd")).to eq [
      %w[sshd -t],
      %w[systemctl try-reload-or-restart ssh.service],
      %w[systemctl try-reload-or-restart fail2ban.service]
    ]
  end

  it "configures no host firewall, which Docker's own rules would bypass (the cloud firewall is the one)" do
    expect(config.to_s).not_to match(/\bufw\b|iptables|nftables/)
  end
end
