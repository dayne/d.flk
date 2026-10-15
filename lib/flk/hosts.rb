module Flk
  # [flk] internal_hosts = true: fly's .internal names without a DNS
  # server. A machine of such an app gets, in /etc/hosts:
  #   IP APP.internal ID.vm.APP.internal NAME.vm.APP.internal
  # for every machine on this host (APP.internal only for running ones, so
  # it lists the app's live machines). The block comes on the config drive
  # at boot (/flk/init appends it), and when a machine starts or stops a
  # detached `flk machine hosts-sync` rewrites it in the running guests
  # through flk-agent (`/flk/agent hosts`). Apps without the key: nothing
  # is written and nothing runs.
  module Hosts
    BEGIN_MARK = "# flk internal hosts (flk rewrites this block)"
    END_MARK = "# end of flk internal hosts"

    module_function

    def wants?(m) = m.config["internal_hosts"] == true

    # A machine's names, as on its line: APP.internal first while it runs.
    def names(m, running: m.running?)
      a = m.app.name
      [*("#{a}.internal" if running), "#{m.id}.vm.#{a}.internal", "#{m.name}.vm.#{a}.internal"]
    end

    # booting: a machine about to start (counted as running).
    def block(booting: nil)
      lines = App.all.flat_map do |a|
        a.machines.sort_by { _1.h["tap_index"].to_i }.map do |m|
          "#{m.ip} #{names(m, running: m.id == booting&.id || m.running?).join(' ')}"
        end
      end
      [BEGIN_MARK, *lines, END_MARK].join("\n") + "\n"
    end

    def digest(text) = Digest::SHA256.hexdigest(text)[0, 16]

    # For the config drive: the block, or nil when the machine doesn't want it.
    def for_boot(m)
      return nil unless wants?(m)
      text = block(booting: m)
      File.write(m.path("hosts.sha"), digest(text))
      text
    end

    # Called on every machine event: starts a sync only when some running
    # machine wants the names (so, for most hosts, never).
    def changed!
      return unless App.all.any? { |a| a.machines.any? { wants?(_1) && _1.running? } }
      log = File.join(ROOT, "hooks.log")
      pid = Process.spawn({ "FLK_HOME" => ROOT, "FLK_TMUX_SOCKET" => VM::SOCKET },
                          RbConfig.ruby, BIN, "machine", "hosts-sync",
                          in: File::NULL, out: File::NULL, err: [log, "a"], pgroup: true)
      Process.detach(pid)
    rescue StandardError
      nil
    end

    # Pushes the current block to every running machine that wants it and
    # doesn't have it yet. One sync at a time; each reads the state when it
    # gets the lock, so the last one always wins.
    def sync!
      File.open(File.join(ROOT, "hosts.lock"), File::RDWR | File::CREAT, 0o644) do |f|
        f.flock(File::LOCK_EX)
        sleep 0.2 # let a burst of events (stop-all, a rolling deploy) settle
        text = block
        sum = digest(text)
        App.all.flat_map(&:machines).select { wants?(_1) && _1.running? }.each do |m|
          next if (File.read(m.path("hosts.sha")) rescue nil) == sum
          if push(m, text)
            File.write(m.path("hosts.sha"), sum)
          else
            warn "[hosts-sync] #{m.app.name} #{m.id}: couldn't update /etc/hosts (agent missing or too old)"
          end
        end
      end
    end

    def push(m, text)
      io = Agent.connect(m)
      io.write(Agent.frame("R", JSON.generate(argv: ["/flk/agent", "hosts"], tty: false, user: "", cwd: "/")))
      io.write(Agent.frame("I", text))
      io.write(Agent.frame("E"))
      while (f = Agent.read_frame(io))
        t, data = f
        return JSON.parse(data)["status"].zero? if t == "X"
        return false if t == "F"
      end
      false
    rescue Error, SystemCallError, IOError, JSON::ParserError
      false
    ensure
      io&.close
    end
  end
end
