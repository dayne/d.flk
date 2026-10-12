require "json"
require "fileutils"
require "shellwords"
require "securerandom"
require "time"
require "open3"
require "tmpdir"
require "socket"
require "digest"
require "set"

module Flk
  VERSION = "0.1.0"

  class Error < StandardError; end

  ROOT    = File.expand_path(ENV["FLK_HOME"] ||
              File.join(ENV["XDG_DATA_HOME"] || File.join(Dir.home, ".local/share"), "flk"))
  SHARE   = File.expand_path("../../share", __dir__)
  LIBEXEC = File.expand_path("../../libexec", __dir__)
  BIN     = File.expand_path("../../bin/flk", __dir__)
  # Root-side tools, by absolute path so hints work from any directory
  SETUP_HOST = File.expand_path("../../setup-host.sh", __dir__)
  SANITY     = File.expand_path("../../flk-sanity.sh", __dir__)
  ENV_KEY = /\A[A-Za-z_][A-Za-z0-9_]*\z/

  module Util
    module_function

    def read_json(path, default = nil)
      File.exist?(path) ? JSON.parse(File.read(path)) : default
    end

    # Atomic write so a crash never leaves half a machine.json behind.
    def write_json(path, obj, mode: 0o644)
      FileUtils.mkdir_p(File.dirname(path))
      tmp = "#{path}.#{$$}.tmp"
      File.write(tmp, JSON.pretty_generate(obj) + "\n")
      File.chmod(mode, tmp)
      File.rename(tmp, path)
    end

    # One global lock for anything that allocates taps/volumes.
    # Re-entrant within a process (flock on a second fd would deadlock).
    def with_lock
      return yield if @locked
      FileUtils.mkdir_p(ROOT)
      File.open(File.join(ROOT, ".lock"), File::RDWR | File::CREAT, 0o644) do |f|
        f.flock(File::LOCK_EX)
        @locked = true
        yield
      ensure
        @locked = false
      end
    end

    def which(cmd)
      ENV["PATH"].split(File::PATH_SEPARATOR).map { File.join(_1, cmd) }
                 .find { File.executable?(_1) && !File.directory?(_1) }
    end

    # Capture output; raise with it on failure.
    def run!(*cmd)
      out, status = Open3.capture2e(*cmd)
      raise Error, "command failed (#{status.exitstatus}): #{cmd.shelljoin}\n#{out}" unless status.success?
      out
    end

    # Stream output to the terminal (builds, pulls).
    def sh!(*cmd)
      system(*cmd) or raise Error, "command failed: #{cmd.shelljoin}"
    end

    # Like sh!, streaming output as it comes, but also returns it, so the
    # caller can explain known failures: [output, Process::Status].
    def sh_capture(*cmd)
      out = +""
      Open3.popen2e(*cmd) do |_in, io, wait|
        io.each_line { |l| $stdout.print l; $stdout.flush; out << l }
        [out, wait.value]
      end
    end

    def mkfs_ext4(path, size_mb, label:, from_dir: nil)
      FileUtils.rm_f(path)
      File.open(path, "w") { _1.truncate(size_mb * 1024 * 1024) } # sparse
      cmd = ["mkfs.ext4", "-F", "-q", "-L", label[0, 16]]
      cmd += ["-d", from_dir] if from_dir
      run!(*cmd, path)
    end

    def wait_for(timeout = 5, step = 0.05)
      deadline = Time.now + timeout
      until (ok = yield)
        return false if Time.now > deadline
        sleep step
      end
      ok
    end

    def now = Time.now.utc.iso8601

    def ago(iso)
      return "-" unless iso
      s = (Time.now - Time.parse(iso)).to_i
      case s
      when 0...60 then "#{s}s ago"
      when 60...3600 then "#{s / 60}m ago"
      when 3600...86_400 then "#{s / 3600}h ago"
      else "#{s / 86_400}d ago"
      end
    end

    def table(headers, rows)
      widths = headers.each_index.map { |i| ([headers[i]] + rows.map { _1[i].to_s }).map(&:length).max }
      line = ->(r) { r.each_with_index.map { |c, i| c.to_s.ljust(widths[i]) }.join("  ").rstrip }
      puts line[headers]
      rows.each { puts line[_1] }
    end

    def color? = $stdout.tty? && !ENV["NO_COLOR"]
    def green(s)  = color? ? "\e[32m#{s}\e[0m" : s
    def yellow(s) = color? ? "\e[33m#{s}\e[0m" : s
    def red(s)    = color? ? "\e[31m#{s}\e[0m" : s
  end
end
