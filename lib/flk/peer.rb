module Flk
  # Another flk host, reached over ssh (docs/remote-design.md). A peer is
  # named in flk.toml ([flk] host), with -H, or in FLK_HOST; the name is an
  # ssh destination unless ~/.config/flk/host.toml maps it:
  #
  #   name = "mud"                 # this host's own name (default: hostname)
  #   [peers]
  #     nexus = "dayne@10.47.11.85"
  #
  # Everything sent to a peer is `flk ...` run there, plus rsync of an app's
  # directory before a deploy. FLK_SSH replaces the ssh command (tests).
  module Peer
    NAME = /\A[A-Za-z0-9_][A-Za-z0-9_.@:-]{0,252}\z/ # never starts with "-": it goes on ssh's command line
    LOCAL = "local".freeze
    SSH_FAILED = 255
    MARKER = ".flk-origin".freeze # in a synced copy: where it came from
    IGNORE_FILE = ".flkignore".freeze

    module_function

    # This host's name: what [flk] host must say for an app to run here.
    def self_name
      (Host.settings["name"] || Socket.gethostname.split(".").first).to_s
    end

    def check_name!(name, what = "host")
      raise Error, "#{what} '#{name}' isn't a host name or ssh destination" unless name.to_s.match?(NAME)
      name.to_s
    end

    def peers = Host.settings["peers"] || {}

    def dest(name) = check_name!(peers[name] || name, "peer #{name}'s destination")

    def ssh = ENV["FLK_SSH"].to_s.empty? ? ["ssh"] : ENV["FLK_SSH"].shellsplit

    # What the peer's login shell is handed: one `sh -c` word whose text
    # holds no quote, backslash or `$var` of ours, so bash, zsh and fish all
    # read it the same way. The real script travels as base64 and is
    # written for POSIX sh.
    def remote_line(script)
      b64 = [script].pack("m0")
      %(sh -c 'eval "$(printf %s #{b64} | base64 -d)"')
    end

    # The script that runs `flk ARGV` on the peer.
    # watch: stdin isn't the command's; it is a pipe this side holds open,
    # and when it closes (this flk went away) the peer's flk is stopped, so
    # a `logs -f` cut off here doesn't live on over there.
    def script(argv, dir: nil, env: {}, watch: false)
      lines = ['PATH="$PATH:$HOME/.local/bin"; export PATH']
      env.merge("FLK_HOP" => "1").each { |k, v| lines << "#{k}=#{v.to_s.shellescape}; export #{k}" }
      lines << "cd #{dir.shellescape} || exit 96" if dir
      # FLK_REMOTE_FLK: flk's path on the peer, when it isn't on its PATH
      # (and how a checkout under test is tried on a real peer)
      flk = ENV["FLK_REMOTE_FLK"].to_s.empty? ? "flk" : ENV["FLK_REMOTE_FLK"]
      lines << %(command -v #{flk.shellescape} >/dev/null 2>&1 || { echo "flk: not found on this host (PATH, ~/.local/bin)" >&2; exit 97; })
      cmd = [flk, *argv].shelljoin
      if watch
        lines << "exec 3<&0"
        lines << "#{cmd} </dev/null 3<&- & p=$!"
        lines << '( cat <&3 >/dev/null 2>&1; kill "$p" 2>/dev/null ) & w=$!'
        lines << 'wait "$p"; rc=$?'
        lines << 'kill "$w" 2>/dev/null'
        lines << 'exit "$rc"'
      else
        lines << "exec #{cmd}"
      end
      lines.join("\n")
    end

    def ssh_argv(name, script, tty: false)
      batch = $stdin.tty? ? [] : ["-o", "BatchMode=yes"] # at a terminal, ssh may ask for a passphrase
      # LogLevel=error: no "Connection to X closed." after every command at a terminal
      [*ssh, *batch, "-o", "ConnectTimeout=8", "-o", "LogLevel=error", (tty ? "-t" : "-T"), dest(name), remote_line(script)]
    end

    # Run flk on the peer, its output and input passing straight through.
    # At a terminal the peer's flk gets one too, so it behaves as it would
    # here (colours, `flk logs` following, a confirmation, Ctrl-C).
    # Otherwise, stdin: true hands it this process's stdin (secrets set
    # KEY=-, exec --stdin); for other commands the caller's stdin is left
    # alone. Returns the exit status.
    def run(name, argv, dir: nil, env: {}, stdin: false)
      tty = $stdin.tty? && $stdout.tty?
      if stdin || tty
        system(*ssh_argv(name, script(argv, dir: dir, env: env), tty: tty))
        return $?.exitstatus || 1
      end

      r, w = IO.pipe
      pid = spawn(*ssh_argv(name, script(argv, dir: dir, env: env, watch: true)), in: r)
      r.close
      begin
        Process.wait(pid)
        $?.exitstatus || 1
      rescue Interrupt
        w.close
        Process.wait(pid) rescue nil
        raise
      ensure
        w.close unless w.closed?
      end
    end

    # Run flk on the peer and return [stdout, stderr, status].
    def capture(name, argv, timeout: 20)
      out = err = st = nil
      Timeout.timeout(timeout) do
        out, err, st = Open3.capture3(*ssh_argv(name, script(argv)), stdin_data: "")
      end
      [out, err, st.exitstatus || 1]
    rescue Timeout::Error
      ["", "no answer in #{timeout}s", SSH_FAILED]
    rescue SystemCallError => e
      ["", e.message, SSH_FAILED]
    end

    # What the peer says about itself (flk version --json there):
    # { version, schema, host, root, subnet }. Raises when it can't be asked.
    def hello(name)
      out, err, code = capture(name, %w[version --json])
      if code != 0
        why = err.lines.map(&:strip).reject(&:empty?).last.to_s
        if code == SSH_FAILED
          raise Error, "can't reach #{name} (#{[*ssh, dest(name)].join(' ')}): #{why}"
        elsif code == 97
          raise Error, "#{name} has no flk on its PATH or in ~/.local/bin (there: flk setup --fix)"
        elsif why.include?("--json") || why.include?("unexpected argument")
          raise Error, "#{name}'s flk is older than this one (#{VERSION}) and can't be deployed to from here: update it there"
        end
        raise Error, "#{name}: flk version --json failed: #{why}"
      end
      JSON.parse(out)
    rescue JSON::ParserError
      raise Error, "#{name}: flk version --json printed something else: #{out.to_s.lines.first.to_s.strip}"
    end

    # Where an app's directory is kept on a peer whose state dir is root.
    def src_dir(root, app) = File.join(root, "src", app)

    # Copy an app's directory to the peer: everything but .git and what
    # .flkignore lists (hooks need the repo's scripts and its site.env).
    # Files that are gone here go there too; ignored ones are left alone.
    def sync(name, dir, remote_dir)
      raise Error, "rsync is needed to send #{dir} to #{name}" unless Util.which("rsync")
      # rsync splits -e on spaces and reads quotes, not backslashes (shelljoin's BatchMode\=yes)
      rsh = [*ssh, "-o", "BatchMode=yes", "-o", "ConnectTimeout=8"].map { _1.match?(%r{\A[\w@%+=:,./-]+\z}) ? _1 : "'#{_1}'" }.join(" ")
      cmd = ["rsync", "-a", "-s", "--delete", "--mkpath", "-e", rsh, "--exclude=/.git/", "--filter=P /#{MARKER}"]
      ignore = File.join(dir, IGNORE_FILE)
      cmd << "--exclude-from=#{ignore}" if File.exist?(ignore)
      out, st = Open3.capture2e(*cmd, "#{dir.chomp('/')}/", "#{dest(name)}:#{remote_dir}/")
      raise Error, "rsync of #{dir} to #{name} failed: #{out.lines.last(3).join.strip}" unless st.success?
    end

    # Where this copy of the source is from, for the release made from it:
    # { host, path, commit, dirty } (commit and dirty are nil outside git).
    def origin(dir)
      commit = dirty = nil
      if Util.which("git")
        out, st = Open3.capture2e("git", "-C", dir, "rev-parse", "--short=12", "HEAD")
        if st.success?
          commit = out.strip
          dirty = !Open3.capture2e("git", "-C", dir, "status", "--porcelain").first.strip.empty?
        end
      end
      { "host" => self_name, "path" => dir, "commit" => commit, "dirty" => dirty }
    end

    # The origin handed to this flk by the one that sent the source (deploy).
    def origin_from_env
      v = ENV["FLK_ORIGIN"].to_s
      return nil if v.empty?
      h = JSON.parse(v)
      h.is_a?(Hash) ? h.slice("host", "path", "commit", "dirty") : nil
    rescue JSON::ParserError
      nil
    end

    def origin_label(o)
      return nil unless o.is_a?(Hash) && o["host"]
      [o["host"], o["commit"] && "@#{o['commit']}", ("+" if o["dirty"])].compact.join
    end

    # ---------- apps this host deployed to a peer ----------
    # FLK_HOME/remote_apps.json: { APP: { host, config_path, at } }, so
    # `flk -a APP ...` finds the app's host from any directory.

    def registry_path = File.join(ROOT, "remote_apps.json")
    def remote_apps = Util.read_json(registry_path, {})

    def record_app(app, host, config_path)
      Util.with_lock do
        h = remote_apps
        h[app] = { "host" => host, "config_path" => config_path, "at" => Util.now }
        Util.write_json(registry_path, h)
      end
    end

    def forget_app(app)
      Util.with_lock do
        h = remote_apps
        Util.write_json(registry_path, h) if h.delete(app)
      end
    end
  end
end
