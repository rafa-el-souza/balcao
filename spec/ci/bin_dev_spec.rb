require "rails_helper"
require "json"
require "pty"
require "rbconfig"
require "timeout"
require "tmpdir"

# bin/dev runs Rails and the Vite dev server from the owner's interactive
# terminal. It is copied into a scratch app whose bin/rails and npm are fake
# servers that report their process group, the terminal's foreground group
# and whether their stdin is a terminal, then sleep. Linux only (/proc).
RSpec.describe "NFR-08 bin/dev in an interactive terminal" do
  let(:root) { Dir.mktmpdir("bin-dev") }
  let(:shims) { File.join(root, "shims") }

  before do
    FileUtils.mkdir_p([ File.join(root, "bin"), File.join(root, "web"), shims ])
    FileUtils.cp(Rails.root.join("bin/dev"), File.join(root, "bin/dev"))
    write_fake_server(File.join(root, "bin/rails"), "rails")
    write_fake_server(File.join(shims, "npm"), "web")
  end

  after do
    reported_pids.each { |pid| Process.kill("KILL", pid) rescue Errno::ESRCH }
    [ @dev, @leader ].compact.each { |pid| Process.kill("KILL", pid) rescue Errno::ESRCH }
    FileUtils.remove_entry(root)
  end

  def write_fake_server(path, name)
    File.write(path, <<~RUBY)
      #!/usr/bin/env ruby
      require "json"
      stat = File.read("/proc/self/stat").split(") ", 2).last.split
      report = { pid: Process.pid, pgrp: stat[2].to_i, tpgid: stat[5].to_i, stdin_tty: STDIN.tty? }
      File.write(#{File.join(root, "#{name}.json").inspect}, JSON.dump(report))
      sleep
    RUBY
    File.chmod(0o755, path)
  end

  # As under a shell, bin/dev is not the terminal's session leader: a small
  # Ruby process is, and it records bin/dev's pid and exit status.
  def start_dev(path: "#{shims}#{File::PATH_SEPARATOR}#{ENV.fetch("PATH")}")
    leader = <<~RUBY
      pid = Process.spawn(#{File.join(root, "bin/dev").inspect})
      File.write(#{File.join(root, "dev.pid").inspect}, pid.to_s)
      _, status = Process.wait2(pid)
      File.write(#{File.join(root, "dev.status").inspect}, status.success?.to_s)
      sleep
    RUBY
    @terminal, @keyboard, @leader = PTY.spawn({ "PATH" => path }, RbConfig.ruby, "-e", leader)
    Thread.new { loop { @terminal.readpartial(4096) } rescue nil }
    pid_file = File.join(root, "dev.pid")
    Timeout.timeout(20) { sleep 0.05 until File.size?(pid_file) }
    @dev = File.read(pid_file).to_i
  end

  def dev_status
    file = File.join(root, "dev.status")
    Timeout.timeout(20) { sleep 0.05 until File.size?(file) }
    File.read(file) == "true"
  end

  def report(name)
    file = File.join(root, "#{name}.json")
    Timeout.timeout(20) { sleep 0.05 until File.size?(file) }
    JSON.parse(File.read(file))
  end

  def reported_pids = %w[rails web].filter_map { |name| JSON.parse(File.read(File.join(root, "#{name}.json")))["pid"] rescue nil }

  # Review finding R3 on pull request #4: Vite reads keyboard shortcuts from a
  # terminal stdin; from a background process group that read stops it.
  it "gives the web dev server no terminal to read" do
    start_dev

    expect(report("web")["stdin_tty"]).to be false
  end

  # Review finding R3b on pull request #4: Rails in its own process group
  # froze at a debugger breakpoint, which reads the terminal.
  it "keeps Rails in the terminal's foreground process group, with the terminal on its stdin" do
    start_dev
    rails = report("rails")

    expect(rails["stdin_tty"]).to be true
    expect(rails["pgrp"]).to eq rails["tpgid"]
  end

  it "stops Rails when bin/dev is interrupted" do
    start_dev
    rails = report("rails")
    report("web")

    Process.kill("INT", @dev)

    Timeout.timeout(10) { sleep 0.05 until gone?(rails["pid"]) }
  end

  # Review finding V1 (verifier, pull request #4): when bin/dev died other
  # than by INT or TERM, the servers it had started survived it, so the next
  # bin/dev could not bind port 3000.
  it "stops both servers when the terminal hangs up" do
    start_dev
    pids = [ report("rails")["pid"], report("web")["pid"] ]

    [ @keyboard, @terminal ].each(&:close)

    Timeout.timeout(10) { sleep 0.05 until pids.all? { |pid| gone?(pid) } }
  end

  it "stops Rails and fails when the web dev server cannot be started" do
    start_dev(path: RbConfig::CONFIG.fetch("bindir"))

    expect(dev_status).to be false
    Timeout.timeout(10) { sleep 0.05 until live_processes_under_root.empty? }
  end

  def live_processes_under_root
    Dir.glob("/proc/[0-9]*").select do |dir|
      File.readlink("#{dir}/cwd") == File.realpath(root) &&
        File.read("#{dir}/cmdline").include?("bin/rails") && !gone?(File.basename(dir))
    rescue Errno::ENOENT, Errno::ESRCH, Errno::EACCES
      false
    end
  end

  def gone?(pid)
    stat = File.read("/proc/#{pid}/stat")
    stat.split(") ", 2).last.start_with?("Z")
  rescue Errno::ENOENT
    true
  end
end
