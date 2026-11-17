module Flk
  # flk events, logs, console, exec, ssh console, proxy
  class CLI
    private

    def cmd_events(_args, o)
      raise Error, "--all and -a don't go together" if o[:all] && @app_name
      name = o[:all] ? nil : (@app_name || (AppConfig.find&.app rescue nil))
      since = o[:since] && parse_since(o[:since])
      n = o[:lines] || 50
      show = lambda do |ev|
        if o[:json]
          puts JSON.generate(ev)
        else
          t = (Time.parse(ev["at"]).localtime.strftime("%Y-%m-%d %H:%M:%S") rescue ev["at"])
          puts [t, name ? nil : ev["app"], ev["machine"] || "-", ev["type"], ev["release"] ? "v#{ev['release']}" : nil, ev["detail"]]
            .compact.join("  ")
        end
      end
      if o[:follow]
        Events.follow(app: name, since: since, backlog: n) { show.call(_1) }
      else
        evs = Events.read(app: name, since: since)
        evs = evs.last(n) unless since
        return puts("No events#{" for #{name}" if name}#{" since #{since}" if since}") if evs.empty? && !o[:json]
        evs.each { show.call(_1) }
      end
    rescue Interrupt
      nil
    end

    # ISO time, or a duration back from now: 30s, 10m, 2h, 3d.
    def parse_since(s)
      if (md = /\A(\d+)([smhd])\z/.match(s))
        return (Time.now - md[1].to_i * { "s" => 1, "m" => 60, "h" => 3600, "d" => 86_400 }[md[2]]).utc.iso8601(3)
      end
      Time.parse(s).utc.iso8601(3)
    rescue ArgumentError
      raise Error, "--since takes an ISO time (2026-10-13T12:00:00Z) or a duration (30s, 10m, 2h, 3d)"
    end

    # Follows only when someone is watching: an agent or a pipe would wait forever.
    def cmd_logs(_args, o)
      raise Error, "--follow and --no-tail contradict each other" if o[:follow] && o[:no_tail]
      ms = o[:instance] ? [app.machine!(o[:instance])] : app.machines
      files = ms.map { _1.path("console.log") }.select { File.exist?(_1) }
      raise Error, "no logs yet" if files.empty?
      follow = o[:follow] || (!o[:no_tail] && $stdout.tty?)
      exec("tail", "-n", (o[:lines] || 50).to_s, *(follow ? ["-F"] : []), *files)
    end

    def cmd_console(argv, o)
      return console_send(argv, o) if o[:send]
      raise Error, "--wait-log and --timeout go with --send" if o[:wait_log] || o[:timeout]
      unless $stdin.tty? && $stdout.tty?
        raise Error, "console needs an interactive terminal; to type a line: flk console [ID] --send TEXT; for output: flk logs"
      end
      m = console_machine(argv)
      # flk's sessions live on their own tmux server, so from inside the user's
      # tmux this is a nested attach: the outer tmux sees Ctrl-b first.
      detach = ENV["TMUX"] ? "Ctrl-b Ctrl-b d" : "Ctrl-b d"
      puts "Attaching to #{m.name} serial console (detach: #{detach})"
      sleep 0.5
      exec({ "TMUX" => nil }, *VM::TMUX, "attach", "-t", m.session)
    end

    def cmd_exec(argv, o)
      raise Error, "exec needs a command, e.g. flk exec -- ls /" if argv.empty?
      raise Error, "--tty needs a terminal here (stdin and stdout)" if o[:tty] && !($stdin.tty? && $stdout.tty?)
      m = console_machine(o[:instance] ? [o[:instance]] : [])
      req = { argv: argv, tty: o[:tty] || false, user: o[:user].to_s, cwd: o[:cwd].to_s }
      exit Agent.run(m, req, stdin: o[:stdin], timeout: o[:timeout])
    end

    def ssh_console(argv, o)
      return console_send(argv, o) if o[:send]
      raise Error, "--wait-log and --timeout go with --send" if o[:wait_log] || o[:timeout]
      m = console_machine(argv)
      if o[:command]
        exit Agent.run(m, { argv: ["sh", "-c", o[:command]], tty: false, user: o[:user].to_s }, stdin: !$stdin.tty?)
      end
      unless $stdin.tty? && $stdout.tty?
        raise Error, "an interactive shell needs a terminal; to run a command: flk ssh console -C CMD, or flk exec -- CMD"
      end
      puts "Connecting to #{m.name} (#{m.id}); exit the shell to leave"
      exit Agent.run(m, { argv: [], tty: true, user: o[:user].to_s })
    end

    def ssh_mount(argv, o)
      raise Error, "usage: flk ssh mount PATH DIR (PATH in the machine, DIR here), e.g. flk ssh mount /data ./data" unless argv.size == 2
      path, dir = argv
      a = app
      m = console_machine([o[:instance]].compact)
      opts = o[:option].to_s.split(",").map(&:strip).reject(&:empty?)
      dir = SshMount.mount!(m, path, dir, user: o[:user], read_only: o[:read_only], options: opts)
      how = ["as #{o[:user] || 'root'}", ("read-only" if o[:read_only])].compact.join(", ")
      puts "#{Util.green('✔')} #{a.name}:#{path} is mounted at #{dir} (#{how}; machine #{m.id} [#{m.name}])"
      puts "  It follows the machine through restarts and deploys. While the machine is stopped, files there fail with I/O errors."
      next_step("flk ssh unmount #{dir.shellescape}", "flk ssh mounts")
    end

    def ssh_unmount(argv, o)
      raise Error, "give one directory, or --all for every mount of the app" if argv.size > 1 || (argv.empty? && !o[:all]) || (argv.any? && o[:all])
      rows = SshMount.list
      if o[:all]
        name = app.name
        mine = rows.select { _1["app"] == name }
        return puts("No flk ssh mounts of #{name}") if mine.empty?
        mine.each { |r| unmount_row(r, o[:force]) }
      else
        dir = File.expand_path(argv.first)
        row = rows.find { _1["dir"] == dir } or
          raise Error.new("#{dir} isn't a flk ssh mount", next_steps: ["flk ssh mounts"])
        unmount_row(row, o[:force])
      end
    end

    def unmount_row(row, force)
      SshMount.unmount!(row["dir"], lazy: force)
      puts "Unmounted #{row['dir']} (#{row['app']}:#{row['path']})"
    end

    def ssh_mounts(_argv, o)
      rows = SshMount.list
      return puts(JSON.pretty_generate(rows)) if o[:json]
      return puts("No flk ssh mounts. Make one: flk ssh mount PATH DIR") if rows.empty?
      Util.table(%w[APP MACHINE PATH DIR USER MODE STATE],
                 rows.map { [_1["app"], _1["machine"], _1["path"], _1["dir"], _1["user"], _1["read_only"] ? "ro" : "rw", _1["state"]] })
    end

    # sshfs runs this in place of ssh, with ssh's arguments after "--":
    # among them the mount's source, USER@MACHINE.APP.flk, which says where
    # to go. Its stdin and stdout become the machine's SFTP server's.
    def ssh_sftp_stdio(argv, o)
      user, id, name = argv.lazy.filter_map { SshMount.parse_source(_1) }.first ||
                       raise(Error, "flk ssh sftp-stdio is run by sshfs for flk ssh mount; it isn't a command to use by hand")
      a = App.new(name)
      m = (a.exists? && a.machines.find { _1.id == id }) or raise Error, "no machine #{id} in app #{name}"
      req = { argv: SshMount.argv("serve", *("-R" if o[:read_only])), tty: false, user: user == "root" ? "" : user }
      exit Agent.run(m, req, stdin: true)
    end

    def console_machine(argv)
      m = argv.first ? app.machine!(argv.first) : (app.machines.find(&:running?) || raise(Error, "no running machines"))
      raise Error, "machine #{m.id} isn't running; start it: flk machine start #{m.id}" unless m.running?
      m
    end

    # One line into the app's stdin, without attaching. With --wait-log,
    # stream what the console prints next until a line matches.
    def console_send(argv, o)
      text = o[:send]
      raise Error, "--send takes one line (no newlines or control characters)" if text.match?(/[\x00-\x1f\x7f]/)
      re = begin
        o[:wait_log] && Regexp.new(o[:wait_log])
      rescue RegexpError => e
        raise Error, "bad --wait-log regex: #{e.message}"
      end
      m = console_machine(argv)
      if m.config["stdin"] == "null"
        raise Error, "#{m.app.name} has [flk] stdin = \"null\": the app doesn't read the console"
      end
      log = m.path("console.log")
      offset = File.size?(log) || 0
      VM.send_line(m, text)
      return puts("Sent to #{m.id} [#{m.name}]: #{text}") unless re
      wait_for_log(log, offset, re, text, o[:timeout] || 10)
    end

    # Prints new console.log lines from offset until one matches re (the echo
    # of what was typed doesn't count). Follows a rotation to a fresh file.
    def wait_for_log(log, offset, re, typed, timeout)
      deadline = Time.now + timeout
      partial = +""
      loop do
        size = File.size?(log) || 0
        offset = 0 if size < offset # rotated
        if size > offset
          chunk = File.open(log, "rb") { |f| f.seek(offset); f.read(size - offset) }
          offset = size
          lines = (partial + chunk).split("\n", -1)
          partial = lines.pop.to_s
          lines.each do |l|
            l = l.delete("\r")
            next if l.strip == typed.strip # the console's echo
            puts l
            return if l.match?(re)
          end
        end
        raise Error, "no console line matched /#{re.source}/ within #{timeout}s" if Time.now > deadline
        sleep 0.2
      end
    end

    # The bridge is already routable from the host; this is for binding
    # a stable localhost port (or exposing on the LAN with --bind 0.0.0.0).
    def cmd_proxy(argv, o)
      spec = argv.shift
      raise Error, "LOCAL[:REMOTE] must be ports, e.g. 8080 or 8080:80 (got '#{spec}')" unless spec.match?(/\A\d+(:\d+)?\z/)
      lport, rport = spec.split(":", 2).map(&:to_i)
      rport = lport if rport.nil? || rport.zero?
      m = argv.first ? app.machine!(argv.first) : (app.machines.find(&:running?) || raise(Error, "no running machines"))
      bind = o[:bind] || "127.0.0.1"
      server = TCPServer.new(bind, lport)
      puts "Proxying #{bind}:#{lport} -> #{m.name} (#{m.ip}:#{rport})  Ctrl-C to stop"
      loop do
        Thread.new(server.accept) do |c|
          up = TCPSocket.new(m.ip, rport)
          t = Thread.new do
            IO.copy_stream(c, up)
          rescue IOError, SystemCallError
            nil
          ensure
            up.close_write rescue nil
          end
          begin
            IO.copy_stream(up, c)
          rescue IOError, SystemCallError
            nil
          end
          t.join
        rescue SystemCallError => e
          warn "proxy: #{e.message}"
        ensure
          c.close rescue nil
          up&.close rescue nil
        end
      end
    end
  end
end
