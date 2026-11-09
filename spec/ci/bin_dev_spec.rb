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
    Process.kill("KILL", @dev) if @dev rescue Errno::ESRCH
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

  def start_dev(path: "#{shims}#{File::PATH_SEPARATOR}#{ENV.fetch("PATH")}")
    @terminal, @keyboard, @dev = PTY.spawn({ "PATH" => path }, File.join(root, "bin/dev"))
    Thread.new { loop { @terminal.readpartial(4096) } rescue nil }
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
end
