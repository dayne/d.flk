module Flk
  # Drives one firecracker process per machine. Each runs inside a
  # detached tmux session, so the serial console is attachable
  # (flk console) and its output is piped to console.log (flk logs).
  module VM
    module_function

    # flk's own tmux server, separate from the user's. A tmux server keeps the
    # groups it started with, so sharing a long-lived personal one can leave
    # firecracker without the kvm group even after the user logs back in.
    SOCKET = ENV.fetch("FLK_TMUX_SOCKET", "flk")
    TMUX = ["tmux", "-L", SOCKET].freeze
    # console.log rotates to console.log.1 past this (see libexec/flk-logpipe)
    LOG_MAX_BYTES = Integer(ENV.fetch("FLK_LOG_MAX_MB", "10")) * 1024 * 1024

    def firecracker_bin
      ENV["FLK_FIRECRACKER"] ||
        [File.join(ROOT, "bin/firecracker")].find { File.executable?(_1) } ||
        Util.which("firecracker") ||
        raise(Error, "firecracker not found; run: flk setup")
    end

    def kernel = ENV["FLK_KERNEL"] || File.join(ROOT, "kernel/vmlinux")

    def boot_args(m)
      ["console=ttyS0", "reboot=k", "panic=1", "pci=off", "init=/flk/init",
       Net.kernel_ip_arg(m.tap_index, m.name), m.config["kernel_args"]].compact.join(" ")
    end

    # Drive order fixes guest device names: rootfs=vda, config=vdb, volumes=vdc+
    def drives(m)
      d = [
        { "drive_id" => "rootfs", "path_on_host" => m.path("rootfs.ext4"), "is_root_device" => true,  "is_read_only" => false },
        { "drive_id" => "config", "path_on_host" => m.path("config.ext4"), "is_root_device" => false, "is_read_only" => true }
      ]
      m.config["mounts"].each_with_index do |mt, i|
        d << { "drive_id" => "vol#{i}", "path_on_host" => m.app.volume!(mt["volume"])["path"],
               "is_root_device" => false, "is_read_only" => false }
      end
      d
    end

    # Same shape as firecracker's --config-file, kept as vm.json for debugging.
    def spec(m)
      {
        "boot-source" => { "kernel_image_path" => kernel, "boot_args" => boot_args(m) },
        "drives" => drives(m),
        "machine-config" => { "vcpu_count" => m.config["cpus"], "mem_size_mib" => m.config["memory_mb"] }
          .merge(m.config["huge_pages"] ? { "huge_pages" => FC_HUGE_PAGES.fetch(m.config["huge_pages"]) } : {}),
        "network-interfaces" => [{ "iface_id" => "eth0", "guest_mac" => m.mac, "host_dev_name" => Net.tap(m.tap_index) }]
      }
    end

    # Per-boot read-only drive: env + secrets + mount table, read by /flk/init.
    # Rebuilt on every start, so `flk secrets set` + restart just works.
    def build_config_drive(m)
      Dir.mktmpdir("flk-cfg") do |d|
        env = {
          "FLK_APP_NAME" => m.app.name, "FLY_APP_NAME" => m.app.name,
          "FLK_MACHINE_ID" => m.id, "FLY_MACHINE_ID" => m.id,
          "FLK_HOSTNAME" => m.name, "FLK_IP" => m.ip, "FLY_PRIVATE_IP" => m.ip,
          "FLK_PREFIX" => "24", "FLK_GATEWAY" => Net::GATEWAY, "FLK_DNS" => Net::DNS,
          "FLY_REGION" => "local", "FLK_RELEASE" => "v#{m.release}",
          "FLK_STDIN" => m.config["stdin"] || "console"
        }.merge(m.config["env"] || {}).merge(m.app.secrets)
        File.write(File.join(d, "env"), env.map { |k, v| "export #{k}=#{v.to_s.shellescape}\n" }.join)
        File.write(File.join(d, "mounts"), m.config["mounts"].each_with_index.map { |mt, i|
          "/dev/vd#{('c'.ord + i).chr} #{mt['destination']}\n"
        }.join)
        File.chmod(0o600, File.join(d, "env"))
        if (hosts = Hosts.for_boot(m))
          File.write(File.join(d, "hosts"), hosts)
        end
        Util.mkfs_ext4(m.path("config.ext4"), 8, label: "flk-config", from_dir: d)
        File.chmod(0o600, m.path("config.ext4"))
      end
    end

    def preflight!(m)
      raise AlreadyRunning, "machine #{m.id} is already running" if m.running?
      raise Error, "/dev/kvm not accessible; run: sudo #{SETUP_HOST}, then log out/in" unless File.writable?("/dev/kvm")
      raise Error, "guest kernel not found at #{kernel}; run: flk setup" unless File.exist?(kernel)
      raise Error, "#{Net.tap(m.tap_index)} missing; run: sudo #{SETUP_HOST}" unless Net.tap_exists?(m.tap_index)
      raise Error, "tmux is required" unless Util.which("tmux")
      if (pid = backup_pid(m))
        raise Error, "a backup of its volume is running (flk, pid #{pid}); the machine starts again when it's done"
      end
      if (why = huge_pages_short(huge_pages_needed(m.config), huge_pool[:available]))
        raise Error, "machine #{m.id} #{why}"
      end
      m.config["mounts"].each do |mt|
        v = m.app.volume!(mt["volume"])
        next if File.exist?(v["path"])
        raise Error, "volume #{v['name']}'s file #{v['path']} is missing" +
                     (App.external_volume?(v) ? " (is its disk mounted?)" : "")
      end
      if tmux_server_lacks_kvm?
        # The server outlives its sessions (see install_exit_hook); when it's
        # idle, restarting it with the current groups is safe.
        if tmux_sessions.empty?
          tmux_quiet("kill-server")
        else
          raise Error, "flk's tmux server started before you joined the kvm group; " \
                       "stop running machines, then: #{TMUX.join(' ')} kill-server"
        end
      end
    end

    # True when flk's tmux server is already running without /dev/kvm's group.
    def tmux_server_lacks_kvm?
      pid = tmux_server_pid or return false
      kvm = File.stat("/dev/kvm")
      return false if kvm.mode & 0o006 == 0o006 # world read/write
      groups = File.read("/proc/#{pid}/status")[/^Groups:(.*)$/, 1].to_s.split.map(&:to_i)
      !groups.include?(kvm.gid)
    rescue SystemCallError
      false
    end

    def tmux_server_pid
      out, ok = Open3.capture2e(*TMUX, "display-message", "-p", '#{pid}')
      ok.success? ? out.strip.to_i : nil
    end

    # The systemd unit or scope a process lives in, e.g.
    # flk-machines.service, session-68.scope; nil without cgroup v2.
    def cgroup_unit(pid)
      File.read("/proc/#{pid}/cgroup")[%r{^0::.*/([^/\n]+)$}, 1]
    rescue SystemCallError
      nil
    end

    # Under flk's lock, so two flks starting the same machine (flk resume
    # and a restart policy's revive at boot) can't both pass the running
    # check. The cleanup undoes only what launch created: a failed
    # preflight ("already running") must leave the machine that won alone.
    def start(m)
      Util.with_lock do
        preflight!(m)
        begin
          launch(m)
        rescue StandardError
          tmux_quiet("kill-session", "-t", m.session)
          FileUtils.rm_f(m.path("pid"))
          raise
        end
      end
    end

    def launch(m)
      FileUtils.rm_f(m.path("pid")) # stale, from a machine that exited on its own; see reap
      bin = firecracker_bin
      build_config_drive(m)
      s = spec(m)
      Util.write_json(m.path("vm.json"), s)

      sock = m.path("fc.sock")
      fclog = m.path("firecracker.log")
      FileUtils.rm_f(sock)
      FileUtils.touch(fclog)
      File.open(m.path("console.log"), "a") { _1.puts "\n--- flk: booting #{m.id} (release v#{m.release}) at #{Util.now} ---" }
      tmux_quiet("kill-session", "-t", m.session)
      ensure_server # before new-session, which would start one in our cgroup

      # Boot in two phases: firecracker waits on its API socket, we attach
      # the log pipe, then configure + InstanceStart, so no early boot output is lost.
      Util.run!(*TMUX, "new-session", "-d", "-s", m.session, "-x", "200", "-y", "50",
                "exec #{[bin, '--api-sock', sock, '--log-path', fclog, '--level', 'Warning'].shelljoin}")
      Util.run!(*TMUX, "pipe-pane", "-t", m.session, "-o",
                [File.join(LIBEXEC, "flk-logpipe"), m.path("console.log"), LOG_MAX_BYTES.to_s].shelljoin)
      File.write(m.path("pid"), Util.run!(*TMUX, "display-message", "-p", "-t", m.session, '#{pane_pid}').strip)

      Util.wait_for(5) { File.socket?(sock) } or
        raise Error, "firecracker API socket never appeared; see #{fclog}"
      api(sock, "PUT", "/boot-source", s["boot-source"])
      api(sock, "PUT", "/machine-config", s["machine-config"])
      s["drives"].each { api(sock, "PUT", "/drives/#{_1['drive_id']}", _1) }
      s["network-interfaces"].each { api(sock, "PUT", "/network-interfaces/#{_1['iface_id']}", _1) }
      add_vsock(m, sock)
      api(sock, "PUT", "/actions", { "action_type" => "InstanceStart" })

      m.h["started_at"] = Util.now
      m.h["desired_state"] = "started"
      m.save!
      Ports.sync! if Array(m.config["ports"]).any?
    end

    # The guest's vsock, for flk exec (Agent). Optional: a machine boots
    # without it (a Unix socket path over 107 bytes, an old firecracker).
    def add_vsock(m, sock)
      v = Agent.sock(m)
      FileUtils.rm_f(v)
      return if v.bytesize > 107
      api(sock, "PUT", "/vsock", { "guest_cid" => 3, "uds_path" => v })
    rescue StandardError => e
      warn Util.yellow("    ⚠ no vsock for #{m.id} (flk exec won't work on it): #{e.message}")
    end

    # Graceful: Ctrl-Alt-Del -> guest kernel SIGINTs /flk/init -> app gets
    # SIGTERM -> init reboots -> firecracker exits. After kill_timeout
    # seconds (fly.toml, default 10), TERM/KILL fallbacks.
    # keep_desired: the host is going down (flk stop-all), so flk resume
    # should bring the machine back. sync_ports: false when the caller syncs
    # once for many machines (Ports.sync!'s lock isn't thread-safe).
    def stop(m, timeout: nil, keep_desired: false, sync_ports: true)
      # capped here too: machines deployed before the config check keep their old value
      timeout ||= [(m.config["kill_timeout"] || 10).to_i, AppConfig::MAX_KILL_TIMEOUT].min
      File.write(m.path("stopping"), Util.now) if File.directory?(m.dir) # see Machine#stopping?
      was_running = m.running?
      if was_running
        sent = begin
          api(m.path("fc.sock"), "PUT", "/actions", { "action_type" => "SendCtrlAltDel" })
          true
        rescue StandardError
          false
        end
        unless sent && Util.wait_for(timeout, 0.2) { !m.running? }
          kill(m.pid, "TERM")
          kill(m.pid, "KILL") unless Util.wait_for(3, 0.1) { !m.running? }
        end
      end
      tmux_quiet("kill-session", "-t", m.session)
      FileUtils.rm_f([m.path("pid"), m.path("fc.sock"), Agent.sock(m)])
      m.h["stopped_at"] = Util.now
      m.h["desired_state"] = "stopped" unless keep_desired
      m.save!
      Events.machine("machine.stopped", m, keep_desired ? "to be started again (stop-all, or a backup)" : nil) if was_running
      Ports.sync! if sync_ports && Array(m.config["ports"]).any? # hand its ports to another machine, or drop them
    ensure
      FileUtils.rm_f(m.path("stopping"))
    end

    # Tidy machines that exited on their own (see Machine#exited?) and hand
    # their host ports to the next machine, or drop them, so the port map
    # never points at a dead IP. machine.json is left alone: another flk
    # process may be mid-update on it. A machine the host went down with
    # (pid file from before the boot) isn't revived: flk resume owns it.
    #
    # wait: false (read commands): if another flk holds the lock, e.g. a
    # deploy mid-roll, skip the whole reap rather than hang, and leave the
    # pid files so the next look (or the tmux exit hook, which waits)
    # finishes it. Tidying without syncing would strand the port mapping.
    def reap(machines, wait: true)
      dead = machines.select(&:exited?)
      return if dead.empty?
      rebooted = []
      Util.with_lock(wait: wait) do
        dead.each do |m|
          next unless m.exited? # re-check: another flk may have just restarted it
          if m.exited_before_boot?
            rebooted << m
            Events.machine("machine.exited", m, "the host went down with it running (flk resume brings it back)")
          else
            st = m.last_exit_status
            Events.machine("machine.exited", m, st ? "the app exited with status #{st}" : "no exit status (crashed or killed)")
          end
          tmux_quiet("kill-session", "-t", m.session)
          FileUtils.rm_f([m.path("pid"), m.path("fc.sock")])
        end
        Ports.sync! if dead.any? { Array(_1.config["ports"]).any? }
        (dead - rebooted).select { restart_wanted?(_1) }.each { spawn_revive(_1) }
      end
    end

    # Should its restart policy bring this exited machine back?
    def restart_wanted?(m)
      return false unless m.desired_state == "started"
      case m.restart_policy["policy"]
      when "always" then true
      when "on-failure" then m.last_exit_status != 0 # nil (crash) counts as a failure
      else false
      end
    end

    # `flk machine revive` in the background: it waits out the backoff and
    # boots, so whoever noticed the exit (the tmux hook, a status call)
    # returns at once.
    def spawn_revive(m)
      log = File.join(ROOT, "hooks.log")
      pid = Process.spawn({ "FLK_HOME" => ROOT, "FLK_TMUX_SOCKET" => SOCKET },
                          RbConfig.ruby, BIN, "-a", m.app.name, "machine", "revive", m.id,
                          in: File::NULL, out: File::NULL, err: [log, "a"], pgroup: true)
      Process.detach(pid)
    end

    def wait_port(m, port, timeout = 30)
      Util.wait_for(timeout, 0.5) do
        raise Error, "machine #{m.id} exited during boot; check: flk logs -i #{m.id} --no-tail" unless m.running?
        begin
          Socket.tcp(m.ip, port, connect_timeout: 1) { true }
        rescue SystemCallError, IOError
          false
        end
      end
    end

    # Tiny HTTP/1.1 client over firecracker's unix socket.
    def api(sock, method, path, body = nil)
      payload = body ? JSON.generate(body) : ""
      UNIXSocket.open(sock) do |s|
        s.write("#{method} #{path} HTTP/1.1\r\nHost: localhost\r\nAccept: application/json\r\n" \
                "Content-Type: application/json\r\nContent-Length: #{payload.bytesize}\r\n\r\n#{payload}")
        head = +""
        head << s.readpartial(4096) until head.include?("\r\n\r\n")
        header, rest = head.split("\r\n\r\n", 2)
        status = header[%r{\AHTTP/1\.[01] (\d{3})}, 1].to_i
        len = header[/^Content-Length:\s*(\d+)/i, 1].to_i
        rest << s.readpartial(4096) while rest.bytesize < len
        raise Error, "firecracker #{method} #{path} -> #{status}: #{rest.strip}" unless (200..299).cover?(status)
        rest.empty? ? nil : JSON.parse(rest)
      end
    end

    # A stop-mode backup is copying this machine's volume: the pid of that
    # flk, while it lives.
    def backup_pid(m)
      pid = File.read(m.path("backup")).to_i
      pid.positive? && Process.kill(0, pid) ? pid : nil
    rescue SystemCallError
      nil
    end

    def pause(m) = api(m.path("fc.sock"), "PATCH", "/vm", { "state" => "Paused" })
    def resume(m) = api(m.path("fc.sock"), "PATCH", "/vm", { "state" => "Resumed" })

    # CPU and memory of running machines, from /proc of each firecracker
    # process (the VM: its RSS is guest memory actually touched). CPU is
    # one sample over `sample` seconds for all machines at once.
    def stats(machines, sample: 0.5)
      hz = Etc.sysconf(Etc::SC_CLK_TCK).to_f
      live = machines.select(&:running?).to_h { [_1.id, _1.pid] }
      t0 = live.transform_values { proc_ticks(_1) }
      sleep sample if live.any?
      t1 = live.transform_values { proc_ticks(_1) }
      up = File.read("/proc/uptime").to_f
      machines.map do |m|
        h = { "app" => m.app.name, "id" => m.id, "name" => m.name, "state" => m.state, "pid" => live[m.id],
              "cpus" => m.config["cpus"], "memory_mb" => m.config["memory_mb"],
              "cpu_percent" => nil, "rss_mb" => nil, "uptime_s" => nil }
        a = t0[m.id]
        b = t1[m.id]
        if a && b
          h["cpu_percent"] = ((b[0] - a[0]) / hz / sample * 100).round(1)
          h["rss_mb"] = proc_rss_mb(live[m.id])
          h["uptime_s"] = (up - b[1] / hz).round
        end
        h
      end
    end

    # [utime + stime, starttime] in clock ticks; nil if the process is gone.
    def proc_ticks(pid)
      f = File.read("/proc/#{pid}/stat").split(") ", 2)[1].split # field 3 onwards
      [f[11].to_i + f[12].to_i, f[19].to_i]
    rescue SystemCallError, NoMethodError
      nil
    end

    # Resident memory, including hugetlbfs pages (not part of VmRSS).
    def proc_rss_mb(pid)
      st = File.read("/proc/#{pid}/status")
      kb = st[/^VmRSS:\s+(\d+)/, 1] or return nil
      ((kb.to_i + st[/^HugetlbPages:\s+(\d+)/, 1].to_i) / 1024.0).round
    rescue SystemCallError
      nil
    end

    FC_HUGE_PAGES = { "2M" => "2M" }.freeze

    # The host's 2M hugetlbfs pool: { total:, free:, rsvd:, available: }
    # (available = free minus pages promised to running VMs).
    def huge_pool
      mi = File.read("/proc/meminfo")
      n = ->(k) { mi[/^#{k}:\s+(\d+)/, 1].to_i }
      { total: n["HugePages_Total"], free: n["HugePages_Free"], rsvd: n["HugePages_Rsvd"],
        available: n["HugePages_Free"] - n["HugePages_Rsvd"], size_kb: n["Hugepagesize"] }
    rescue SystemCallError
      { total: 0, free: 0, rsvd: 0, available: 0, size_kb: 2048 }
    end

    def huge_pages_needed(mconfig) = mconfig["huge_pages"] == "2M" ? mconfig["memory_mb"].to_i / 2 : 0

    # Why a pool of `extra` more pages is needed, with the root commands
    # that reserve it (persistently: /etc/sysctl.d), or nil.
    def huge_pages_short(need, have)
      return nil if need <= have
      pool = huge_pool
      want = pool[:total] + (need - have)
      "needs #{need} free 2M huge pages, #{have} available (pool #{pool[:total]}). Reserve more (root), then retry:\n" \
        "  sudo sysctl -w vm.nr_hugepages=#{want}\n" \
        "  echo 'vm.nr_hugepages = #{want}' | sudo tee /etc/sysctl.d/60-flk-hugepages.conf\n" \
        "  (check HugePages_Total in /proc/meminfo: on a busy host the kernel may find fewer; a reboot always works)"
    end

    def kill(pid, sig)
      Process.kill(sig, pid) if pid
    rescue SystemCallError
      nil
    end

    # Types a line into the machine's serial console (the app's stdin):
    # literal text, then Enter.
    def send_line(m, text)
      Util.run!(*TMUX, "send-keys", "-t", m.session, "-l", text)
      Util.run!(*TMUX, "send-keys", "-t", m.session, "Enter")
    end

    # `tmux ls` exits 0 with no sessions on a server kept alive by exit-empty off
    def tmux_sessions
      out, st = Open3.capture2e(*TMUX, "list-sessions", "-F", '#{session_name}')
      st.success? ? out.split("\n") : []
    end

    # When firecracker exits on its own (the app quit, the guest powered off,
    # it crashed), its tmux session closes and this hook runs `flk ports reap`:
    # the machine is tidied and its host ports handed on within a second, with
    # no daemon. exit-empty off keeps the server, and so the hook, alive when
    # the last session closes, the common "my only machine died" case.
    # Start flk's tmux server if it isn't running. The server, and so every
    # machine, lives in the cgroup of whoever starts it, and shutdown kills a
    # login session's before flk-machines.service can stop anything
    # (../mud BUGS.flk.md #3). So with flk-tmux.service installed, systemd
    # starts it, through the port helper; without (no boot service: a dev
    # host), the caller does, as before.
    def ensure_server
      start_server_unit if server_unit? && !tmux_server_pid
      tmux_quiet("start-server", ";", "set-option", "-g", "exit-empty", "off")
      install_exit_hook
    end

    SERVER_UNIT = "flk-tmux.service"

    # Test servers (FLK_TMUX_SOCKET) are never the unit's.
    def server_unit? = SOCKET == "flk" && File.exist?("/etc/systemd/system/#{SERVER_UNIT}")

    # The helper queues the start (--no-block) and this waits for the
    # server, so a start from inside another unit's start job can't deadlock.
    def start_server_unit
      out, st = Open3.capture2e("sudo", "-n", Ports::HELPER, "start-tmux")
      why = if !st.success? then out.strip.lines.last&.strip
            elsif !Util.wait_for(10, 0.2) { tmux_server_pid } then "it didn't come up in 10s"
            end
      return unless why
      raise Error.new("can't start #{SERVER_UNIT} (#{why}): machines started without it " \
                      "would be killed, not stopped, at shutdown",
                      next_steps: ["systemctl status #{SERVER_UNIT}", "sudo #{SETUP_HOST} (updates the port helper)"])
    rescue SystemCallError => e
      raise Error, "can't start #{SERVER_UNIT}: #{e.message}"
    end

    def install_exit_hook
      log = File.join(ROOT, "hooks.log")
      cmd = "FLK_HOME=#{ROOT.shellescape} FLK_TMUX_SOCKET=#{SOCKET.shellescape} " \
            "#{hook_bin.shellescape} ports reap >/dev/null 2>>#{log.shellescape}"
      raise Error, "can't install the exit hook: a path contains a single quote" if cmd.include?("'")
      tmux_quiet("set-option", "-g", "exit-empty", "off")
      tmux_quiet("set-hook", "-g", "session-closed", "run-shell -b '#{cmd}'")
    end

    # The flk the exit hook should run: on flk's real tmux server, the one
    # flk-machines.service runs (the host's stable checkout) when that's
    # installed, so running flk from another checkout (a git worktree, a
    # manual test) never repoints it; else this flk. A test's own tmux
    # server (FLK_TMUX_SOCKET) always gets this flk.
    def hook_bin
      return BIN unless SOCKET == "flk"
      svc = File.read("/etc/systemd/system/flk-machines.service")[%r{^ExecStart=-?\S+ (/\S+/bin/flk) resume}, 1]
      svc && File.executable?(svc) ? svc : BIN
    rescue SystemCallError
      BIN
    end

    # The flk binary the exit hook runs, or nil (no server, or no hook).
    def exit_hook_bin
      out, st = Open3.capture2e(*TMUX, "show-hooks", "-g", "session-closed")
      st.success? ? out[%r{(/\S+/bin/flk) ports reap}, 1] : nil
    end

    def tmux_quiet(*args) = system(*TMUX, *args, out: File::NULL, err: File::NULL)
  end
end
