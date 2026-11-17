module Flk
  # flk ssh mount: a directory of a running machine, mounted on the host
  # with sshfs. No sshd, keys or network in the guest: sshfs is told to run
  # libexec/flk-sftp (`flk ssh sftp-stdio`) in place of ssh, and that runs the image's SFTP
  # server through flk-agent (as `flk exec` runs any command), as the user
  # asked for. Needs sshfs here and an sftp-server in the image.
  #
  # Nothing is recorded: the kernel's mount table is the list. The mount's
  # source names everything the stand-in needs, USER@MACHINE.APP.flk (sshfs
  # passes it on as the "host"), so a reconnect after the machine restarts
  # finds its way back.
  module SshMount
    # Where distributions put OpenSSH's sftp-server (it's rarely on PATH).
    SERVERS = %w[/usr/lib/ssh/sftp-server /usr/lib/openssh/sftp-server /usr/libexec/openssh/sftp-server
                 /usr/libexec/sftp-server /usr/lib/sftp-server /usr/lib64/ssh/sftp-server
                 /usr/lib64/misc/sftp-server].freeze

    # Run in the guest with sh: `probe DIR` prints the server's path (127
    # none, 66 DIR isn't a directory, 77 this user can't enter it); `serve
    # [FLAGS]` becomes the server. It starts in the user's home, whose
    # owner sshfs takes for "the remote user" (idmap=user).
    SCRIPT = <<~SH.freeze
      mode=$1; shift
      for s in "$(command -v sftp-server 2>/dev/null)" #{SERVERS.join(' ')}; do
        [ -n "$s" ] && [ -x "$s" ] || continue
        if [ "$mode" = probe ]; then
          [ -d "$1" ] || exit 66
          [ -r "$1" ] && [ -x "$1" ] || exit 77
          echo "$s"; exit 0
        fi
        cd "${HOME:-/}" 2>/dev/null || cd /
        exec "$s" "$@"
      done
      echo "flk: no sftp-server in this image" >&2
      exit 127
    SH

    NO_SERVER = "has no SFTP server. Add it in the Dockerfile and deploy: " \
                "Ubuntu/Debian `RUN apt-get update && apt-get install -y --no-install-recommends openssh-sftp-server`, " \
                "Alpine `RUN apk add --no-cache openssh-sftp-server`, Fedora `RUN dnf install -y openssh-server` " \
                "(no sshd needed)".freeze
    INSTALL = "install sshfs (Debian/Ubuntu: sudo apt install sshfs; Arch: sudo pacman -S sshfs; " \
              "Fedora: sudo dnf install fuse-sshfs)".freeze

    SOURCE_RE = /\A(.+)@(\h+)\.([a-z0-9][a-z0-9-]*)\.flk\z/

    module_function

    def sshfs = Util.which("sshfs")
    def fusermount = Util.which("fusermount3") || Util.which("fusermount")

    # Why mounting can't work on this host, or nil.
    def host_problem
      return "sshfs isn't installed: #{INSTALL}" unless sshfs
      return "no /dev/fuse on this host (the fuse kernel module)" unless File.exist?("/dev/fuse")
      "no fusermount3: #{INSTALL}" unless fusermount
    end

    # "1000:1000" can't be in a host name sshfs splits at ":".
    def source(m, user) = "#{user.to_s.empty? ? 'root' : user.tr(':', '+')}@#{m.id}.#{m.app.name}.flk"

    # [user, machine id, app name] from a source, or nil if it isn't ours.
    def parse_source(src)
      m = SOURCE_RE.match(src.to_s) or return nil
      [m[1].tr("+", ":"), m[2], m[3]]
    end

    def argv(mode, *rest) = ["sh", "-c", SCRIPT, "flk-sftp", mode, *rest]

    # The path of the image's sftp-server, after checking that `user` can
    # enter `path` in machine m. Raises with what to do otherwise.
    def probe!(m, path, user)
      out = StringIO.new
      err = StringIO.new
      st = Timeout.timeout(30) do
        Agent.run(m, { argv: argv("probe", path), tty: false, user: user.to_s }, out: out, err: err, signals: false)
      end
      who = user.to_s.empty? ? "root" : user
      case st
      when 0 then out.string.strip
      when 127
        if err.string.include?("no sftp-server")
          raise Error.new("the image of #{m.app.name} #{NO_SERVER}",
                          next_steps: ["flk deploy (after adding it to the Dockerfile)", "flk help dockerfile"])
        end
        raise Error, "the image of #{m.app.name} has no sh, which flk ssh mount needs to start the SFTP server"
      when 66 then raise Error, "#{path} isn't a directory in machine #{m.id}"
      when 77 then raise Error, "#{who} can't read #{path} in machine #{m.id} (try another --user)"
      else raise Error, "couldn't check machine #{m.id} (exit #{st}): #{err.string.strip.lines.last.to_s.strip}"
      end
    rescue Timeout::Error
      raise Error, "machine #{m.id} didn't answer within 30s"
    rescue Error => e
      raise unless e.message.include?("sh: not found in the machine")
      raise Error, "the image of #{m.app.name} has no sh, which flk ssh mount needs to start the SFTP server"
    end

    # What sshfs runs in place of ssh: libexec/flk-sftp, by name. sshfs
    # splits ssh_command at spaces and can't take a path with one in it, so
    # mount! puts the script's directory on sshfs's PATH instead (the
    # daemon keeps it for its reconnects).
    LIBEXEC = File.expand_path("../../libexec", __dir__)

    def ssh_command(read_only) = ["flk-sftp", ("--read-only" if read_only), "--"].compact.join(" ")

    # The directory to mount on, made if missing. An existing one must be
    # empty: a mount would hide what's in it.
    def target!(dir)
      dir = File.expand_path(dir)
      if (row = list.find { _1["dir"] == dir })
        raise Error, "#{dir} already has #{row['app']}:#{row['path']} mounted; flk ssh unmount #{dir}"
      end
      raise Error, "#{dir} is a mount point already" if mount_point?(dir)
      if File.exist?(dir)
        raise Error, "#{dir} isn't a directory" unless File.directory?(dir)
        raise Error, "#{dir} isn't empty; mount on an empty directory (the mount would hide what's in it)" unless Dir.empty?(dir)
      else
        FileUtils.mkdir_p(dir)
      end
      dir
    rescue SystemCallError => e
      raise Error, "can't use #{dir}: #{e.message}"
    end

    def mount!(m, path, dir, user: nil, read_only: false, options: [])
      if (why = host_problem)
        raise Error, why
      end
      raise Error, "the path in the machine must be absolute (got '#{path}')" unless path.start_with?("/")
      probe!(m, path, user)
      dir = target!(dir)
      # dcache_timeout: sshfs's default of 20s is long to wait for what the
      # app wrote, or to keep listing a stopped machine's files
      opts = ["ssh_command=#{ssh_command(read_only)}", "reconnect", "idmap=user", "transform_symlinks",
              "dcache_timeout=5", ("ro" if read_only), *options].compact
      cmd = [sshfs, *opts.flat_map { ["-o", _1] }, "#{source(m, user)}:#{path}", dir]
      out, st = Open3.capture2e({ "PATH" => "#{LIBEXEC}:#{ENV['PATH']}" }, *cmd, in: File::NULL)
      raise Error, "sshfs failed (exit #{st.exitstatus}): #{out.strip.lines.last(3).join.strip}" unless st.success?
      dir
    end

    # Every flk mount on this host, from the kernel's table:
    # [{ app, machine, user, path, dir, read_only, state }]. state: "ok",
    # "machine stopped" (files fail with I/O errors until it starts) or
    # "machine gone".
    def list
      File.foreach("/proc/self/mounts").filter_map do |line|
        src, dir, type, opts = line.split
        next unless type == "fuse.sshfs"
        host, path = unescape(src).split(":", 2)
        user, id, app = parse_source(host)
        next unless app
        { "app" => app, "machine" => id, "user" => user, "path" => path.to_s.empty? ? "/" : path,
          "dir" => unescape(dir), "read_only" => opts.to_s.split(",").include?("ro"), "state" => state(app, id) }
      end
    rescue StandardError # flk status reads this: it must never fail on a mount table it can't read
      []
    end

    def state(app, id)
      a = App.new(app)
      m = a.exists? && a.machines.find { _1.id == id }
      return "machine gone" unless m
      m.running? ? "ok" : "machine stopped"
    rescue Error
      "machine gone"
    end

    # /proc/mounts writes space, tab, newline and backslash as \ooo.
    def unescape(s) = s.gsub(/\\([0-7]{3})/) { $1.oct.chr }

    def mount_point?(dir)
      File.foreach("/proc/self/mounts").any? { unescape(_1.split[1].to_s) == dir }
    rescue SystemCallError
      false
    end

    # lazy: detach now even if something has it open (fusermount -z).
    def unmount!(dir, lazy: false)
      tool = fusermount or raise Error, "no fusermount3 to unmount with: #{INSTALL}"
      out, st = Open3.capture2e(tool, "-u", *("-z" if lazy), dir)
      return true if st.success?
      if out.include?("busy") && !lazy
        raise Error.new("couldn't unmount #{dir}: something has a file open there, or a shell is in it",
                        next_steps: ["flk ssh unmount #{dir.shellescape} --force (detach it now)"])
      end
      raise Error, "couldn't unmount #{dir}: #{out.strip.lines.last.to_s.strip.sub(/\A\S*fusermount3?: /, '')}"
    end

    # Detach the mounts of an app (or one machine of it) that's going away;
    # never raises. Returns the directories.
    def unmount_for(app, machine = nil)
      list.select { _1["app"] == app && (machine.nil? || _1["machine"] == machine) }.filter_map do |row|
        unmount!(row["dir"], lazy: true) && row["dir"]
      rescue Error
        nil
      end
    rescue StandardError
      []
    end
  end
end
