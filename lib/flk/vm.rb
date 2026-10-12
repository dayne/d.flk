module Flk
  # Drives one firecracker process per machine. Each runs inside a
  # detached tmux session, so the serial console is attachable
  # (flk console) and its output is piped to console.log (flk logs).
  module VM
    module_function

    # flk's own tmux server, separate from the user's. A tmux server keeps the
    # groups it started with, so sharing a long-lived personal one can leave
    # firecracker without the kvm group even after the user logs back in.
    TMUX = ["tmux", "-L", ENV.fetch("FLK_TMUX_SOCKET", "flk")].freeze

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
        "machine-config" => { "vcpu_count" => m.config["cpus"], "mem_size_mib" => m.config["memory_mb"] },
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
          "FLY_REGION" => "local", "FLK_RELEASE" => "v#{m.release}"
        }.merge(m.config["env"] || {}).merge(m.app.secrets)
        File.write(File.join(d, "env"), env.map { |k, v| "export #{k}=#{v.to_s.shellescape}\n" }.join)
        File.write(File.join(d, "mounts"), m.config["mounts"].each_with_index.map { |mt, i|
          "/dev/vd#{('c'.ord + i).chr} #{mt['destination']}\n"
        }.join)
        File.chmod(0o600, File.join(d, "env"))
        Util.mkfs_ext4(m.path("config.ext4"), 8, label: "flk-config", from_dir: d)
        File.chmod(0o600, m.path("config.ext4"))
      end
    end

    def preflight!(m)
      raise Error, "machine #{m.id} is already running" if m.running?
      raise Error, "/dev/kvm not accessible; run: sudo ./setup-host.sh, then log out/in" unless File.writable?("/dev/kvm")
      raise Error, "guest kernel not found at #{kernel}; run: flk setup" unless File.exist?(kernel)
      raise Error, "#{Net.tap(m.tap_index)} missing; run: sudo ./setup-host.sh" unless Net.tap_exists?(m.tap_index)
      raise Error, "tmux is required" unless Util.which("tmux")
      if tmux_server_lacks_kvm?
        raise Error, "flk's tmux server started before you joined the kvm group; " \
                     "stop running machines, then: #{TMUX.join(' ')} kill-server"
      end
    end

    # True when flk's tmux server is already running without /dev/kvm's group.
    def tmux_server_lacks_kvm?
      out, ok = Open3.capture2e(*TMUX, "display-message", "-p", '#{pid}')
      return false unless ok.success?
      kvm = File.stat("/dev/kvm")
      return false if kvm.mode & 0o006 == 0o006 # world read/write
      groups = File.read("/proc/#{out.strip.to_i}/status")[/^Groups:(.*)$/, 1].to_s.split.map(&:to_i)
      !groups.include?(kvm.gid)
    rescue SystemCallError
      false
    end

    def start(m)
      preflight!(m)
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

      # Boot in two phases: firecracker waits on its API socket, we attach
      # the log pipe, then configure + InstanceStart, so no early boot output is lost.
      Util.run!(*TMUX, "new-session", "-d", "-s", m.session, "-x", "200", "-y", "50",
                "exec #{[bin, '--api-sock', sock, '--log-path', fclog, '--level', 'Warning'].shelljoin}")
      Util.run!(*TMUX, "pipe-pane", "-t", m.session, "-o", "cat >> #{m.path('console.log').shellescape}")
      File.write(m.path("pid"), Util.run!(*TMUX, "display-message", "-p", "-t", m.session, '#{pane_pid}').strip)

      Util.wait_for(5) { File.socket?(sock) } or
        raise Error, "firecracker API socket never appeared; see #{fclog}"
      api(sock, "PUT", "/boot-source", s["boot-source"])
      api(sock, "PUT", "/machine-config", s["machine-config"])
      s["drives"].each { api(sock, "PUT", "/drives/#{_1['drive_id']}", _1) }
      s["network-interfaces"].each { api(sock, "PUT", "/network-interfaces/#{_1['iface_id']}", _1) }
      api(sock, "PUT", "/actions", { "action_type" => "InstanceStart" })

      m.h["started_at"] = Util.now
      m.save!
      Ports.sync! if Array(m.config["ports"]).any?
    rescue StandardError
      tmux_quiet("kill-session", "-t", m.session)
      FileUtils.rm_f(m.path("pid"))
      raise
    end

    # Graceful: Ctrl-Alt-Del -> guest kernel SIGINTs /flk/init -> app gets
    # SIGTERM -> init reboots -> firecracker exits. After kill_timeout
    # seconds (fly.toml, default 10), TERM/KILL fallbacks.
    def stop(m, timeout: nil)
      # capped here too: machines deployed before the config check keep their old value
      timeout ||= [(m.config["kill_timeout"] || 10).to_i, AppConfig::MAX_KILL_TIMEOUT].min
      if m.running?
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
      FileUtils.rm_f([m.path("pid"), m.path("fc.sock")])
      m.h["stopped_at"] = Util.now
      m.save!
      Ports.sync! if Array(m.config["ports"]).any? # hand its ports to another machine, or drop them
    end

    # Tidy machines that exited on their own (see Machine#exited?) and hand
    # their host ports to the next machine, or drop them, so the port map
    # never points at a dead IP. machine.json is left alone: another flk
    # process may be mid-update on it.
    def reap(machines)
      dead = machines.select(&:exited?)
      return if dead.empty?
      dead.each do |m|
        next unless m.exited? # re-check: another flk may have just restarted it
        tmux_quiet("kill-session", "-t", m.session)
        FileUtils.rm_f([m.path("pid"), m.path("fc.sock")])
      end
      Ports.sync! if dead.any? { Array(_1.config["ports"]).any? }
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

    def kill(pid, sig)
      Process.kill(sig, pid) if pid
    rescue SystemCallError
      nil
    end

    def tmux_quiet(*args) = system(*TMUX, *args, out: File::NULL, err: File::NULL)
  end
end
