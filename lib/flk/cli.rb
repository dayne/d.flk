require "optparse"

module Flk
  class CLI
    HELP = <<~TXT.freeze
      flk: fly.io-style workflow for local Firecracker microVMs

      Usage: flk <command> [-a APP] [options]

      Setup
        setup                       Download firecracker + guest kernel into #{ROOT}
        doctor [--json]             Check host readiness

      Apps
        launch [--name N] [--image I] [--port P] [--no-deploy]
        deploy [--image I]          Build image, roll machines to a new release
        status                      App + machine overview
        releases                    Release history
        apps list | destroy NAME [--yes]
        config show                 Print parsed flk.toml / fly.toml

      Machines
        machine list|start|stop|restart|destroy [-f]|status|config ID...
        scale count N
        logs [-i ID] [-n LINES] [--no-tail]
        console [ID]                Attach serial console (detach: Ctrl-b d)
        proxy LOCAL[:REMOTE] [ID] [--bind ADDR]
        ports [sync]                Host ports forwarded to machines ([[services.ports]])

      Config & data
        secrets list | set K=V... | unset K... | import   [--stage]
        volumes list | create NAME [-s GB] | destroy ID|NAME

      Reads flk.toml, or an existing fly.toml as-is. State lives in #{ROOT}
    TXT

    def self.start(argv) = new.run(argv)

    def run(argv)
      argv = extract_global(argv)
      cmd = argv.shift
      case cmd
      when nil, "help", "-h", "--help" then puts HELP
      when "version", "--version" then puts "flk #{VERSION}"
      when "setup" then cmd_setup
      when "doctor" then cmd_doctor(argv)
      when "launch" then cmd_launch(argv)
      when "deploy" then cmd_deploy(argv)
      when "status" then cmd_status
      when "releases" then cmd_releases
      when "machine", "machines", "m" then cmd_machine(argv)
      when "scale" then cmd_scale(argv)
      when "logs" then cmd_logs(argv)
      when "console" then cmd_console(argv)
      when "ssh" then argv.shift == "console" ? cmd_console(argv) : raise(Error, "only 'flk ssh console' is supported")
      when "secrets" then cmd_secrets(argv)
      when "volumes", "volume", "vol" then cmd_volumes(argv)
      when "proxy" then cmd_proxy(argv)
      when "ports" then cmd_ports(argv)
      when "apps" then cmd_apps(argv)
      when "config" then cmd_config(argv)
      else raise Error, "unknown command '#{cmd}' (try: flk help)"
      end
    rescue Error, OptionParser::ParseError => e
      warn "#{Util.red('Error:')} #{e.message}"
      exit 1
    rescue Interrupt
      exit 130
    end

    private

    # ---------- context ----------

    def extract_global(argv)
      out = []
      it = argv.each
      loop do
        a = it.next
        case a
        when "-a", "--app" then @app_name = it.next
        when /\A--app=(.+)\z/ then @app_name = $1
        else out << a
        end
      end
      out
    end

    def config
      @config ||= AppConfig.find ||
                  raise(Error, "no flk.toml or fly.toml in #{Dir.pwd} (run: flk launch)")
    end

    def app
      @app ||= begin
        name = @app_name || AppConfig.find&.app ||
               raise(Error, "no app: pass -a APP or run inside a directory with flk.toml/fly.toml")
        a = App.new(name)
        raise Error, "app '#{name}' not found (run: flk launch)" unless a.exists?
        a
      end
    end

    def parse(argv, banner)
      opts = {}
      OptionParser.new do |o|
        o.banner = "Usage: flk #{banner}"
        yield o, opts
      end.parse!(argv)
      opts
    end

    # ---------- setup ----------

    def cmd_setup
      Util.sh!(File.join(LIBEXEC, "flk-fetch-assets"))
      puts
      cmd_doctor
    end

    # --json prints {"ok", "checks": [{"label", "status", "hint"}]} for
    # scripts (flk-sanity.sh). status: pass, fail, or warn (works, but a
    # feature like port forwarding is off). ok is false only on a fail.
    def cmd_doctor(argv = [])
      json = argv.delete("--json")
      raise Error, "usage: flk doctor [--json]" unless argv.empty?
      results = []
      icons = { "pass" => Util.green("✔"), "fail" => Util.red("✘"), "warn" => Util.yellow("!") }
      record = lambda do |label, status, hint|
        hint = nil if status == "pass"
        results << { "label" => label, "status" => status, "hint" => hint }
        puts "#{icons[status]} #{label}#{hint ? "  -> #{hint}" : ''}" unless json
      end
      check = ->(label, ok, hint = nil) { record[label, ok ? "pass" : "fail", hint] }
      check["/dev/kvm read/write", File.readable?("/dev/kvm") && File.writable?("/dev/kvm"),
            "sudo ./setup-host.sh (adds you to kvm group; log out/in)"]
      fc = begin; VM.firecracker_bin; rescue Error; nil; end
      check["firecracker #{fc}", !fc.nil?, "flk setup"]
      check["guest kernel #{VM.kernel}", File.exist?(VM.kernel), "flk setup"]
      check["bridge #{Net::BRIDGE}", Net.bridge_up?, "sudo ./setup-host.sh"]
      taps = (0...Net::POOL).count { Net.tap_exists?(_1) }
      check["tap pool #{taps}/#{Net::POOL}", taps.positive?, "sudo ./setup-host.sh"]
      fwd = (File.read("/proc/sys/net/ipv4/ip_forward").strip == "1" rescue false)
      check["ipv4 forwarding", fwd, "sudo ./setup-host.sh"]
      { "tmux" => "tmux", "mkfs.ext4" => "e2fsprogs", "fakeroot" => "fakeroot" }.each do |bin, pkg|
        check[bin, !Util.which(bin).nil?, "install #{pkg}"]
      end
      eng = begin; Image.engine; rescue Error; nil; end
      check["container engine (#{eng || 'none'})", !eng.nil?, "install podman (or docker)"]
      port_helper_check(record)

      ok = results.none? { _1["status"] == "fail" }
      return puts(JSON.pretty_generate("ok" => ok, "checks" => results)) if json
      puts(ok ? "\nReady to fly, locally." : "\nFix the ✘ items above.")
    end

    # Optional: without it machines run, but [[services.ports]] isn't forwarded.
    def port_helper_check(record)
      fix = "sudo ./setup-host.sh"
      if !Ports.available?
        record["port helper (forwarding [[services.ports]])", "warn", fix]
      elsif !system("sudo", "-n", "-l", Ports::HELPER, out: File::NULL, err: File::NULL)
        record["port helper usable without a password", "warn", fix]
      elsif !File.read(Ports::HELPER).match?(/^min_port=/)
        record["port helper up to date (host port guard)", "warn", fix]
      else
        record["port helper (host ports from #{Ports.min_port})", "pass", nil]
      end
    rescue SystemCallError => e
      record["port helper: #{e.message}", "warn", fix]
    end

    # ---------- apps ----------

    def cmd_launch(argv)
      o = parse(argv, "launch [options]") do |p, h|
        p.on("--name NAME") { h[:name] = _1 }
        p.on("--image IMAGE") { h[:image] = _1 }
        p.on("--port PORT", Integer) { h[:port] = _1 }
        p.on("--cpus N", Integer) { h[:cpus] = _1 }
        p.on("--memory MB", Integer) { h[:memory] = _1 }
        p.on("--no-deploy") { h[:no_deploy] = true }
      end

      if (existing = AppConfig.find)
        name = existing.app
        puts "Using existing #{File.basename(existing.path)} (app: #{name})"
      else
        name = o[:name] || File.basename(Dir.pwd).downcase.gsub(/[^a-z0-9-]+/, "-").gsub(/\A-+|-+\z/, "")[0, 63]
        App.new(name) # validates
        File.write("flk.toml", default_toml(name, o))
        puts "Created flk.toml"
      end

      a = App.new(name)
      if a.exists?
        puts "App '#{name}' already registered"
      else
        a.create!
        a.save_meta(a.meta)
        puts "Registered app '#{name}' in #{a.dir}"
      end
      @config = nil

      cfg = config
      buildable = cfg.image || File.exist?(File.expand_path(cfg.dockerfile, cfg.dir))
      if o[:no_deploy] || !buildable
        puts "No Dockerfile or [build] image yet." unless buildable
        puts "Run 'flk deploy' when ready."
      else
        cmd_deploy([])
      end
    end

    def default_toml(name, o)
      build = o[:image] ? "image = #{o[:image].to_s.dump}" : 'dockerfile = "Dockerfile"'
      <<~TOML
        # flk.toml: local Firecracker app config (fly.toml-compatible subset)
        app = "#{name}"

        [build]
          #{build}

        [env]
          # GREETING = "hello"

        [http_service]
          internal_port = #{o[:port] || 8080}

        [[vm]]
          cpus = #{o[:cpus] || 1}
          memory_mb = #{o[:memory] || 256}

        # [[mounts]]
        #   source = "data"        # flk volumes create data --size 1
        #   destination = "/data"
      TOML
    end

    def cmd_deploy(argv)
      o = parse(argv, "deploy [--image IMAGE]") { |p, h| p.on("--image IMAGE") { h[:image] = _1 } }
      cfg = config
      if @app_name && @app_name != cfg.app
        raise Error, "-a #{@app_name} doesn't match app '#{cfg.app}' in #{File.basename(cfg.path)}"
      end
      a = App.new(cfg.app)
      a.create! unless a.exists?
      mconfig = cfg.machine_config

      version = (a.meta["releases"].last&.dig("version") || 0) + 1
      puts "==> Release v#{version} of #{a.name}"
      rel = Image.build(a, cfg, version, image_override: o[:image])

      Util.with_lock do
        meta = a.meta
        meta["releases"] << rel
        a.save_meta(meta)
        machines = a.machines
        if machines.empty?
          count = [meta["scale"] || 1, 1].max
          puts "==> Creating #{count} machine#{'s' if count > 1}"
          count.times { create_machine(a, rel, mconfig) }
        else
          puts "==> Updating #{machines.size} machine#{'s' if machines.size > 1} (rolling)"
          machines.each { update_machine(_1, rel, mconfig) }
        end
      end
      Image.prune(a)

      puts Util.green("\n✔ Deployed #{a.name} v#{version}")
      if (port = mconfig["internal_port"])
        a.machines.each { |m| puts "   #{m.name}  http://#{m.ip}:#{port}" }
      end
    end

    # Every listing command tidies machines that exited on their own, so the
    # host port map follows them (ports are global, hence all apps).
    def reap_exited = VM.reap(App.all.flat_map(&:machines))

    def cmd_status
      reap_exited
      a = app
      rel = a.current_release
      puts "App"
      puts "  Name     = #{a.name}"
      puts "  Release  = #{rel ? "v#{rel['version']} (#{rel['tag']})" : 'none'}"
      puts "  Home     = #{a.dir}"
      puts
      machine_table(a)
    end

    def cmd_releases
      rels = app.meta["releases"]
      return puts("No releases") if rels.empty?
      Util.table(%w[VERSION TAG SOURCE CREATED],
                 rels.reverse.map { ["v#{_1['version']}", _1["tag"], _1["source"], Util.ago(_1["created_at"])] })
    end

    def cmd_apps(argv)
      case (sub = argv.shift || "list")
      when "list", "ls"
        reap_exited
        apps = App.all
        return puts("No apps") if apps.empty?
        Util.table(%w[NAME MACHINES STARTED RELEASE], apps.map do |a|
          ms = a.machines
          [a.name, ms.size, ms.count(&:running?), a.current_release ? "v#{a.current_release['version']}" : "-"]
        end)
      when "destroy"
        name = argv.shift or raise Error, "usage: flk apps destroy NAME [--yes]"
        a = App.new(name)
        raise Error, "no app '#{name}'" unless a.exists?
        unless (argv & %w[--yes -y]).any?
          print "Destroy #{name}, its #{a.machines.size} machine(s) and #{a.volumes.size} volume(s)? [y/N] "
          return puts("Aborted") unless $stdin.gets.to_s.strip.downcase == "y"
        end
        Util.with_lock { a.machines.each { destroy_machine(_1, force: true) } }
        FileUtils.rm_rf(a.dir)
        puts "Destroyed app #{name}"
      else raise Error, "unknown: flk apps #{sub}"
      end
    end

    def cmd_config(argv)
      sub = argv.shift || "show"
      raise Error, "usage: flk config show" unless sub == "show"
      puts JSON.pretty_generate("file" => config.path, "parsed" => config.data, "machine_config" => config.machine_config)
    end

    # ---------- machines ----------

    def machine_table(a)
      ms = a.machines
      return puts("No machines. Run: flk deploy") if ms.empty?
      Util.table(%w[ID NAME STATE RELEASE IP CPUS MEMORY VOLUMES UPDATED], ms.map do |m|
        [m.id, m.name, m.state, "v#{m.release}", m.ip, m.config["cpus"], "#{m.config['memory_mb']}MB",
         m.config["mounts"].map { _1["volume"] }.join(",").then { _1.empty? ? "-" : _1 }, Util.ago(m.updated_at)]
      end)
    end

    def cmd_machine(argv)
      sub = argv.shift || "list"
      force = !(argv & %w[--force -f]).empty?
      argv -= %w[--force -f]
      case sub
      when "list", "ls" then reap_exited; machine_table(app)
      when "start" then each_ref(argv) { |m| boot(m, "Machine #{m.id} [#{m.name}] started") }
      when "stop" then each_ref(argv) { |m| VM.stop(m); puts "Machine #{m.id} [#{m.name}] stopped" }
      when "restart" then each_ref(argv) { |m| VM.stop(m); boot(m, "Machine #{m.id} [#{m.name}] restarted") }
      when "destroy", "rm" then Util.with_lock { each_ref(argv) { |m| destroy_machine(m, force: force) } }
      when "status", "show" then each_ref(argv) { |m| puts JSON.pretty_generate(m.h.merge("state" => m.state)) }
      when "config" then each_ref(argv) { |m| puts JSON.pretty_generate(VM.spec(m)) }
      else raise Error, "usage: flk machine list|start|stop|restart|destroy|status|config ID..."
      end
    end

    def each_ref(argv, &blk)
      raise Error, "machine ID or name required" if argv.empty?
      argv.map { app.machine!(_1) }.each(&blk)
    end

    def cmd_scale(argv)
      unless argv.shift == "count" && argv.first.to_s.match?(/\A\d+\z/)
        raise Error, "usage: flk scale count N"
      end
      n = argv.shift.to_i
      a = app
      Util.with_lock do
        meta = a.meta
        meta["scale"] = n
        a.save_meta(meta)
        rel = a.current_release
        next puts("Scale set to #{n}; applies on first deploy") unless rel

        ms = a.machines
        if n > ms.size
          cfg = AppConfig.find
          base = cfg && cfg.app == a.name ? cfg.machine_config : ms.last&.config&.reject { |k, _| k == "mounts" }
          raise Error, "run from the app directory so flk can read its config" unless base
          (n - ms.size).times { create_machine(a, rel, base) }
        else
          ms.last(ms.size - n).reverse_each { destroy_machine(_1, force: true) }
        end
        puts "Scaled #{a.name} to #{n} machine#{'s' unless n == 1}"
      end
    end

    def create_machine(a, rel, mconfig)
      i = Net.allocate!
      id = SecureRandom.hex(7)
      h = {
        "id" => id, "name" => Machine.generate_name, "app" => a.name,
        "tap_index" => i, "ip" => Net.ip(i), "mac" => Net.mac(i), "release" => rel["version"],
        "config" => mconfig.merge("mounts" => attach_volumes(a, id, mconfig["mount_specs"])),
        "created_at" => Util.now
      }
      m = Machine.new(a, h)
      FileUtils.mkdir_p(m.dir)
      m.save!
      install_rootfs(m, rel)
      boot(m, "Machine #{m.id} [#{m.name}] created")
    end

    def update_machine(m, rel, mconfig)
      puts "  #{m.id} [#{m.name}] stopping" if m.running?
      VM.stop(m)
      m.h["release"] = rel["version"]
      m.h["config"] = mconfig.merge("mounts" => attach_volumes(m.app, m.id, mconfig["mount_specs"]))
      m.save!
      install_rootfs(m, rel)
      boot(m, "Machine #{m.id} [#{m.name}] updated to v#{rel['version']}")
    end

    # Root filesystem is ephemeral per release, exactly like Fly:
    # persistent data belongs on a volume.
    def install_rootfs(m, rel)
      raise Error, "release image missing: #{rel['path']} (redeploy)" unless File.exist?(rel["path"])
      Util.run!("cp", "--reflink=auto", "--sparse=always", rel["path"], m.path("rootfs.ext4"))
    end

    # A volume attaches to exactly one machine. Prefer the one this machine
    # already had, so redeploys never swap data between machines.
    def attach_volumes(a, mid, specs)
      return [] if specs.empty?
      vols = a.volumes
      prev = vols.select { _1["attached_machine"] == mid }.map { _1["id"] }
      vols.each { _1["attached_machine"] = nil if _1["attached_machine"] == mid }
      out = specs.map do |s|
        v = vols.find { _1["name"] == s["source"] && prev.include?(_1["id"]) && _1["attached_machine"].nil? } ||
            vols.find { _1["name"] == s["source"] && _1["attached_machine"].nil? } or
          raise Error, "no unattached volume named '#{s['source']}'; create one: flk volumes create #{s['source']} --size 1"
        v["attached_machine"] = mid
        { "volume" => v["id"], "destination" => s["destination"] }
      end
      a.save_volumes(vols)
      out
    end

    def destroy_machine(m, force: false)
      raise Error, "machine #{m.id} is running; stop it or pass --force" if m.running? && !force
      VM.stop(m)
      vols = m.app.volumes
      vols.each { _1["attached_machine"] = nil if _1["attached_machine"] == m.id }
      m.app.save_volumes(vols)
      FileUtils.rm_rf(m.dir)
      puts "Machine #{m.id} [#{m.name}] destroyed"
    end

    def boot(m, msg)
      VM.start(m)
      puts "  #{Util.green('✔')} #{msg} (#{m.ip})"
      port = m.config["internal_port"] or return m
      if VM.wait_port(m, port, 30)
        puts "    listening on #{m.ip}:#{port}"
      else
        puts Util.yellow("    ⚠ nothing listening on #{m.ip}:#{port} after 30s; check: flk logs -i #{m.id}")
      end
      show_ports(m)
      m
    end

    def show_ports(m)
      Array(m.config["ports"]).each do |p|
        key = "#{p['proto']}/#{p['port']}"
        o = Ports.owner(key)
        if (why = Ports.blocked_reason(p["proto"], p["port"]))
          puts Util.yellow("    ⚠ host port #{key} not forwarded: #{why}")
        elsif o.nil? || !Ports.available?
          next
        elsif o["machine"] == m.id
          puts "    host port #{key} -> #{m.ip}:#{p['internal_port']}"
        else
          puts Util.yellow("    ⚠ host port #{key} is taken by #{o['app']} (#{o['machine']}); this machine gets it when that one stops")
        end
      end
    end

    def cmd_ports(argv)
      case (sub = argv.shift || "list")
      when "sync"
        reap_exited
        Ports.sync! or raise Error, "port forwarding not applied"
        puts "Port forwarding synced"
      when "list", "ls"
        reap_exited
        active, waiting, blocked = Ports.table
        puts Util.yellow("Port helper not installed; run: sudo ./setup-host.sh\n") unless Ports.available?
        return puts("No forwarded ports (add [[services.ports]] to flk.toml)") if [active, waiting, blocked].all?(&:empty?)
        row = ->(r, status) { [r["key"], r["machine"], "#{r['ip']}:#{r['internal_port']}", r["app"], status] }
        Util.table(%w[HOST_PORT MACHINE TARGET APP STATUS],
                   active.map { row[_1, "active"] } + waiting.map { row[_1, "waiting (port taken)"] } +
                   blocked.map { row[_1, "blocked: #{_1['blocked']}"] })
      else raise Error, "usage: flk ports [list|sync]"
      end
    end

    def cmd_logs(argv)
      o = parse(argv, "logs [-i ID] [-n LINES] [--no-tail]") do |p, h|
        p.on("-i", "--instance ID") { h[:machine] = _1 }
        p.on("-n LINES", Integer) { h[:lines] = _1 }
        p.on("--no-tail") { h[:no_tail] = true }
      end
      ms = o[:machine] ? [app.machine!(o[:machine])] : app.machines
      files = ms.map { _1.path("console.log") }.select { File.exist?(_1) }
      raise Error, "no logs yet" if files.empty?
      exec("tail", "-n", (o[:lines] || 50).to_s, *(o[:no_tail] ? [] : ["-F"]), *files)
    end

    def cmd_console(argv)
      m = argv.first ? app.machine!(argv.first) : (app.machines.find(&:running?) || raise(Error, "no running machines"))
      raise Error, "machine #{m.id} isn't running" unless m.running?
      # flk's sessions live on their own tmux server, so from inside the user's
      # tmux this is a nested attach: the outer tmux sees Ctrl-b first.
      detach = ENV["TMUX"] ? "Ctrl-b Ctrl-b d" : "Ctrl-b d"
      puts "Attaching to #{m.name} serial console (detach: #{detach})"
      sleep 0.5
      exec({ "TMUX" => nil }, *VM::TMUX, "attach", "-t", m.session)
    end

    # The bridge is already routable from the host; this is for binding
    # a stable localhost port (or exposing on the LAN with --bind 0.0.0.0).
    def cmd_proxy(argv)
      o = parse(argv, "proxy LOCAL[:REMOTE] [ID] [--bind ADDR]") { |p, h| p.on("--bind ADDR") { h[:bind] = _1 } }
      spec = argv.shift or raise Error, "usage: flk proxy LOCAL[:REMOTE] [ID]"
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

    # ---------- secrets & volumes ----------

    def cmd_secrets(argv)
      a = app
      stage = !argv.delete("--stage").nil?
      sub = argv.shift || "list"
      s = a.secrets
      case sub
      when "list", "ls"
        return puts("No secrets") if s.empty?
        Util.table(%w[NAME DIGEST], s.map { |k, v| [k, Digest::SHA256.hexdigest(v)[0, 16]] })
        return
      when "set"
        raise Error, "usage: flk secrets set KEY=VALUE ... (VALUE '-' reads stdin)" if argv.empty?
        argv.each do |kv|
          k, v = kv.split("=", 2)
          raise Error, "bad secret '#{kv}' (want KEY=VALUE)" if v.nil?
          raise Error, "invalid secret name '#{k}'" unless k.match?(ENV_KEY)
          s[k] = v == "-" ? $stdin.read.chomp : v
        end
      when "import"
        $stdin.each_line do |l|
          next if l.strip.empty? || l.start_with?("#")
          k, v = l.chomp.split("=", 2)
          raise Error, "bad line: #{l.strip}" unless v && k.match?(ENV_KEY)
          s[k] = v
        end
      when "unset"
        argv.each { |k| s.delete(k) or warn "no secret #{k}" }
      else raise Error, "usage: flk secrets list|set|unset|import"
      end
      a.save_secrets(s)
      puts "Secrets updated"
      return puts("Staged; applies on next start/deploy") if stage
      a.machines.select(&:running?).each do |m|
        VM.stop(m)
        boot(m, "Machine #{m.id} [#{m.name}] restarted with new secrets")
      end
    end

    def cmd_volumes(argv)
      a = app
      case (sub = argv.shift || "list")
      when "list", "ls"
        v = a.volumes
        return puts("No volumes") if v.empty?
        Util.table(%w[ID NAME SIZE ATTACHED CREATED],
                   v.map { [_1["id"], _1["name"], "#{_1['size_gb']}GB", _1["attached_machine"] || "-", Util.ago(_1["created_at"])] })
      when "create"
        o = parse(argv, "volumes create NAME [-s GB]") { |p, h| p.on("-s", "--size GB", Integer) { h[:size] = _1 } }
        name = argv.shift or raise Error, "usage: flk volumes create NAME [--size GB]"
        raise Error, "volume names: lowercase letters, digits, underscores" unless name.match?(/\A[a-z0-9_]{1,30}\z/)
        size = o[:size] || 1
        id = "vol_#{SecureRandom.hex(8)}"
        path = File.join(a.dir, "volumes", "#{id}.ext4")
        FileUtils.mkdir_p(File.dirname(path))
        Util.mkfs_ext4(path, size * 1024, label: name)
        Util.with_lock do
          vols = a.volumes
          vols << { "id" => id, "name" => name, "size_gb" => size, "path" => path,
                    "attached_machine" => nil, "created_at" => Util.now }
          a.save_volumes(vols)
        end
        puts "Created #{id} (#{name}, #{size}GB sparse)"
      when "destroy", "rm"
        ref = argv.shift or raise Error, "usage: flk volumes destroy ID|NAME"
        Util.with_lock do
          v = a.volume!(ref)
          if v["attached_machine"]
            raise Error, "#{v['id']} is attached to machine #{v['attached_machine']}; destroy that machine first"
          end
          FileUtils.rm_f(v["path"])
          a.save_volumes(a.volumes.reject { _1["id"] == v["id"] })
          puts "Destroyed #{v['id']}"
        end
      else raise Error, "unknown: flk volumes #{sub}"
      end
    end
  end
end
