require "optparse"

module Flk
  class CLI
    def self.start(argv) = new.run(argv)

    def run(argv)
      argv = extract_global(argv)
      name = argv.shift
      case name
      when nil, "-h", "--help" then return puts(Commands.short_help)
      when "--version" then return cmd_version([], {})
      end
      cmd = Commands.find(name) or
        raise Error, "unknown command '#{name}'#{hint_for(Commands.suggest(name))} (see: flk help)"
      sub = pick_sub(cmd, argv)
      @help_ref = ["flk help", cmd[:name], sub&.dig(:name)].compact.join(" ")
      entry = sub || cmd
      if cmd[:subs] && !sub
        return puts(Commands.command_help(cmd)) if argv.intersect?(%w[-h --help])
        raise Error, "flk #{cmd[:name]} needs a subcommand: #{cmd[:subs].map { _1[:name] }.join(', ')} (see: flk help #{cmd[:name]})"
      end

      opts = parse_opts(entry, argv) or return puts(Commands.command_help(cmd, sub))
      min, max = Commands.arity(entry[:args])
      if argv.size < min || (max && argv.size > max)
        what = argv.size < min ? "missing arguments" : "unexpected argument '#{argv[max]}'"
        raise Error, "#{what}; usage: #{Commands.usage(cmd, sub)}"
      end
      handler = entry[:run] || (sub ? "#{cmd[:name]}_#{sub[:name]}" : "cmd_#{cmd[:name]}")
      send(handler, argv, opts)
    rescue Error, OptionParser::ParseError => e
      msg = e.message.sub(/\n\s*Did you mean\?\s*(\S+).*/m) { "; did you mean --#{$1}?" }
      ref = @help_ref && e.is_a?(OptionParser::ParseError) ? " (see: #{@help_ref})" : ""
      warn "#{Util.red('Error:')} #{msg}#{ref}"
      exit 1
    rescue Interrupt
      exit 130
    end

    private

    # ---------- dispatch ----------

    def hint_for(word) = word ? "; did you mean '#{word}'?" : ""

    # The subcommand named by argv.first, or the default one. Options
    # (-x) before a subcommand, like `flk machine --help`, mean "none given".
    def pick_sub(cmd, argv)
      return nil unless cmd[:subs]
      word = argv.first
      if word && !word.start_with?("-")
        sub = Commands.find(word, cmd[:subs]) or
          raise Error, "unknown subcommand 'flk #{cmd[:name]} #{word}'#{hint_for(Commands.suggest(word, cmd[:subs]))} (see: flk help #{cmd[:name]})"
        argv.shift
        return sub
      end
      return nil if argv.intersect?(%w[-h --help])
      cmd[:default_sub] && Commands.find(cmd[:default_sub], cmd[:subs])
    end

    # Options from the command table; anything else is an error. Returns nil
    # for --help. Positionals stay in argv.
    def parse_opts(entry, argv)
      opts = {}
      help = false
      OptionParser.new do |p|
        p.require_exact = true # no --jso for --json: typos are errors, not guesses
        Array(entry[:opts]).each do |o|
          # a flag is true when given; OptionParser hands "--no-x" flags false
          flag = Commands.switches(o).none? { _1.match?(/[ =]/) }
          p.on(*o) { |v| opts[Commands.key(o)] = flag || v }
        end
        p.on("-h", "--help") { help = true }
      end.parse!(argv)
      help ? nil : opts
    end

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

    # ---------- setup ----------

    def cmd_version(_args, _o) = puts("flk #{VERSION}")

    def cmd_help(args, o)
      if o[:all]
        return puts(JSON.pretty_generate(Commands.to_h)) if o[:json]
        return puts(guide)
      end
      raise Error, "--json goes with --all: flk help --all --json" if o[:json]
      return puts(Commands.short_help) if args.empty?
      cmd = Commands.find(args[0]) or raise Error, "unknown command '#{args[0]}'#{hint_for(Commands.suggest(args[0]))} (see: flk help)"
      sub = args[1] && (Commands.find(args[1], Array(cmd[:subs])) or
                        raise Error, "unknown subcommand 'flk #{cmd[:name]} #{args[1]}' (see: flk help #{cmd[:name]})")
      puts Commands.command_help(cmd, sub)
    end

    # share/guide.md with the generated command reference spliced in.
    def guide
      File.read(File.join(SHARE, "guide.md"))
          .gsub("{{VERSION}}", VERSION).gsub("{{ROOT}}", ROOT).gsub("{{SRC}}", File.dirname(SHARE))
          .gsub("{{COMMANDS}}", Commands.reference_md)
          .gsub("{{JSON_COMMANDS}}", Commands.json_summary)
          .gsub("{{EXIT_CODES}}", Commands::EXIT_CODES.map { |k, v| "- `#{k}`: #{v}" }.join("\n"))
          .gsub("{{MAX_KILL_TIMEOUT}}", AppConfig::MAX_KILL_TIMEOUT.to_s)
    end

    def cmd_setup(_args, _o)
      Util.sh!(File.join(LIBEXEC, "flk-fetch-assets"))
      puts
      cmd_doctor([], {})
    end

    # --json prints {"ok", "checks": [{"label", "status", "hint"}]} for
    # scripts (flk-sanity.sh). status: pass, fail, or warn (works, but a
    # feature like port forwarding is off). ok is false only on a fail.
    def cmd_doctor(_args, o)
      results = doctor_checks
      ok = results.none? { _1["status"] == "fail" }
      return puts(JSON.pretty_generate("ok" => ok, "checks" => results)) if o[:json]
      icons = { "pass" => Util.green("✔"), "fail" => Util.red("✘"), "warn" => Util.yellow("!") }
      results.each { |c| puts "#{icons[c['status']]} #{c['label']}#{c['hint'] ? "  -> #{c['hint']}" : ''}" }
      puts(ok ? "\nReady to fly, locally." : "\nFix the ✘ items above.")
    end

    def doctor_checks
      results = []
      record = lambda do |label, status, hint|
        results << { "label" => label, "status" => status, "hint" => status == "pass" ? nil : hint }
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
      if eng && Image.podman?(eng)
        if Image.short_names_resolve?
          record["podman resolves short image names (FROM ruby:3.3)", "pass", nil]
        else
          record["podman can't resolve short image names like FROM ruby:3.3 (full names work)", "warn", Image::REGISTRIES_FIX]
        end
      end
      port_helper_check(record)
      results
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

    # ---------- context ----------

    def cmd_context(_args, o)
      reap_exited
      c = context
      return puts(JSON.pretty_generate(c)) if o[:json]
      puts context_text(c)
    end

    # Everything an agent (or a person) needs to pick the next command,
    # gathered without failing: problems become next_steps.
    def context
      host = doctor_checks
      c = { "flk" => { "version" => VERSION, "state_dir" => ROOT, "source" => File.dirname(SHARE),
                       "reference" => "flk help --all" },
            "host" => { "ok" => host.none? { _1["status"] == "fail" }, "problems" => host.reject { _1["status"] == "pass" } },
            "cwd" => Dir.pwd, "config" => nil, "app" => nil, "other_apps" => [], "next_steps" => [] }
      steps = c["next_steps"]
      c["host"]["problems"].each { steps << "#{_1['status'] == 'fail' ? 'fix' : 'optional'}: #{_1['label']} -> #{_1['hint']}" }

      cfg = begin
        AppConfig.find
      rescue Error => e
        c["config"] = { "error" => e.message }
        steps << "fix the config file: #{e.message}"
        nil
      end
      if cfg
        c["config"] = { "file" => cfg.path, "app" => (cfg.app rescue nil) }
        begin
          mc = cfg.machine_config
          c["config"]["machine_config"] = mc
        rescue Error => e
          c["config"]["error"] = e.message
          steps << "fix #{File.basename(cfg.path)}: #{e.message}"
        end
      end

      name = @app_name || c.dig("config", "app")
      if name
        c["app"] = app_context(App.new(name), cfg&.app == name ? cfg : nil, steps)
      elsif !c["config"]
        steps << "no flk.toml or fly.toml in #{Dir.pwd}: cd to an app directory, pass -a APP, or create one with: flk launch"
      end
      c["other_apps"] = apps_summary.reject { _1["name"] == name }
      c
    end

    def app_context(a, cfg, steps)
      h = { "name" => a.name, "registered" => a.exists? }
      unless a.exists?
        steps << (cfg ? "register the app: flk launch --no-deploy (then flk deploy)" : "app '#{a.name}' doesn't exist; see: flk apps list")
        return h
      end
      ms = a.machines
      rel = a.current_release
      h.merge!("home" => a.dir, "release" => rel, "releases" => a.meta["releases"].size, "scale" => a.meta["scale"],
               "machines" => ms.map { machine_json(_1) }, "volumes" => a.volumes,
               "secrets" => a.secrets.keys)
      ports = ports_json
      h["ports"] = %w[active waiting blocked].to_h { |k| [k, ports[k].select { _1["app"] == a.name }] }

      # volumes [[mounts]] will need: one unattached per machine per source
      want = [ms.size, a.meta["scale"] || 1].max
      Array(cfg&.mounts).each do |mt|
        have = a.volumes.count { _1["name"] == mt["source"] }
        next if have >= want
        n = want - have
        steps << "[[mounts]] source '#{mt['source']}' needs #{n} more volume#{'s' if n > 1}: " \
                 "flk volumes create #{mt['source']} --size 1#{" (run #{n} times)" if n > 1}"
      end
      if rel.nil?
        steps << (cfg ? "deploy the first release: flk deploy" : "no release yet; run flk deploy from the app directory")
      elsif ms.empty?
        steps << "no machines; flk deploy (or flk scale count 1)"
      end
      ms.reject(&:running?).each do |m|
        steps << "machine #{m.id} [#{m.name}] is stopped; see why: flk logs -i #{m.id} --no-tail; start: flk machine start #{m.id}"
      end
      h["ports"]["blocked"].each { steps << "host port #{_1['key']} not forwarded: #{_1['blocked']}" }
      h["ports"]["waiting"].each { steps << "host port #{_1['key']} is held by another machine; this one gets it when that stops" }
      if rel && cfg && rel["version"] && ms.any? { _1.release != rel["version"] }
        steps << "some machines run an older release; flk deploy rolls them"
      end
      up = ms.select(&:running?)
      if up.any? && steps.none? { !_1.start_with?("optional:") }
        port = up.first.config["internal_port"]
        steps << "all good#{port ? "; try: curl http://#{up.first.ip}:#{port}/" : ''} (logs: flk logs)"
      end
      h
    end

    def context_text(c)
      out = ["# flk context", "",
             "flk #{c['flk']['version']}  state: #{c['flk']['state_dir']}  full reference: flk help --all", "",
             "## Host", c["host"]["ok"] ? "ready" : "NOT ready"]
      c["host"]["problems"].each { out << "- #{_1['status']}: #{_1['label']} -> #{_1['hint']}" }
      out << "" << "## App" << "cwd: #{c['cwd']}"
      if (cf = c["config"])
        out << "config: #{cf['file'] || '(unreadable)'}#{" -- ERROR: #{cf['error']}" if cf['error']}"
      else
        out << "config: none in this directory"
      end
      if (a = c["app"])
        out << "app: #{a['name']}#{' (not registered)' unless a['registered']}"
        if a["registered"]
          rel = a["release"]
          out << "release: #{rel ? "v#{rel['version']} (#{rel['tag']}), #{a['releases']} total" : 'none'}"
          out << "machines: #{a['machines'].empty? ? 'none' : ''}"
          a["machines"].each do |m|
            out << "- #{m['id']} [#{m['name']}] #{m['state']} v#{m['release']} #{m['ip']}" \
                   "#{m['internal_port'] ? ":#{m['internal_port']}" : ''}"
          end
          out << "volumes: #{a['volumes'].map { "#{_1['name']}=#{_1['id']}(#{_1['attached_machine'] || 'free'})" }.join(', ').then { _1.empty? ? 'none' : _1 }}"
          out << "secrets: #{a['secrets'].empty? ? 'none' : a['secrets'].join(', ')}"
          ports = a["ports"]
          rows = ports["active"].map { "#{_1['key']} -> #{_1['ip']}:#{_1['internal_port']} (active)" } +
                 ports["waiting"].map { "#{_1['key']} (waiting: held by another machine)" } +
                 ports["blocked"].map { "#{_1['key']} (blocked: #{_1['blocked']})" }
          out << "host ports: #{rows.empty? ? 'none' : rows.join('; ')}"
        end
      else
        out << "app: none (pass -a APP or cd to a directory with flk.toml)"
      end
      unless c["other_apps"].empty?
        out << "" << "## Other apps"
        c["other_apps"].each { out << "- #{_1['name']}: #{_1['started']}/#{_1['machines']} machines started" }
      end
      out << "" << "## Next steps"
      c["next_steps"].each { out << "- #{_1}" }
      out << "- nothing obvious; see: flk help" if c["next_steps"].empty?
      out.join("\n")
    end

    # ---------- apps ----------

    def cmd_launch(_args, o)

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
        cmd_deploy([], {})
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

    def cmd_deploy(_args, o)
      cfg = config
      if @app_name && @app_name != cfg.app
        raise Error, "-a #{@app_name} doesn't match app '#{cfg.app}' in #{File.basename(cfg.path)}"
      end
      a = App.new(cfg.app)
      a.create! unless a.exists?
      mconfig = cfg.machine_config

      deploy_capacity!(a, mconfig) # before the slow build
      version = (a.meta["releases"].last&.dig("version") || 0) + 1
      puts "==> Release v#{version} of #{a.name}"
      recorded = false
      begin
        rel = Image.build(a, cfg, version, image_override: o[:image])
        Util.with_lock do
          machines = deploy_capacity!(a, mconfig) # again: things may have changed during the build
          # Record the release only once its machines can be rolled, so a
          # failed precondition never leaves a release with nothing on it.
          meta = a.meta
          meta["releases"] << rel
          a.save_meta(meta)
          recorded = true
          if machines.empty?
            count = [meta["scale"] || 1, 1].max
            puts "==> Creating #{count} machine#{'s' if count > 1}"
            count.times { create_machine(a, rel, mconfig) }
          else
            puts "==> Updating #{machines.size} machine#{'s' if machines.size > 1} (rolling)"
            machines.each { update_machine(_1, rel, mconfig) }
          end
        end
      ensure
        FileUtils.rm_f(File.join(a.dir, "images", "v#{version}.ext4")) unless recorded
      end
      Image.prune(a)

      puts Util.green("\n✔ Deployed #{a.name} v#{version}")
      if (port = mconfig["internal_port"])
        a.machines.each { |m| puts "   #{m.name}  http://#{m.ip}:#{port}" }
      end
    end

    # Raises unless the deploy can create or update all its machines; returns
    # the machines it will update (none on a first deploy).
    def deploy_capacity!(a, mconfig)
      machines = a.machines
      if machines.empty?
        check_capacity!(a, mconfig, creating: [a.meta["scale"] || 1, 1].max)
      else
        check_capacity!(a, mconfig, updating: machines)
      end
      machines
    end

    # Volumes and taps for `creating` new machines plus `updating` existing
    # ones (which may keep the volumes they hold). One volume per machine
    # per [[mounts]] entry, as attach_volumes hands them out.
    def check_capacity!(a, mconfig, creating: 0, updating: [])
      ids = updating.map(&:id)
      need = creating + updating.size
      vols = a.volumes
      Array(mconfig["mount_specs"]).group_by { _1["source"] }.each do |src, specs|
        want = need * specs.size
        free = vols.count { _1["name"] == src && (_1["attached_machine"].nil? || ids.include?(_1["attached_machine"])) }
        next if free >= want
        raise Error, "not enough free volumes for [[mounts]] source '#{src}' (need #{want}, #{free} free; one per machine); " \
                     "create #{want - free} more: flk volumes create #{src} --size 1"
      end
      return if creating.zero? || (taps = Net.free_count) >= creating
      raise Error, "need #{creating} free tap#{'s' if creating > 1} for new machines, #{taps} free; " \
                   "re-run: sudo FLK_TAPS=#{Net::POOL * 2} ./setup-host.sh"
    end

    # Every listing command tidies machines that exited on their own, so the
    # host port map follows them (ports are global, hence all apps).
    def reap_exited = VM.reap(App.all.flat_map(&:machines))

    def cmd_status(_args, o)
      reap_exited
      a = app
      rel = a.current_release
      if o[:json]
        return puts(JSON.pretty_generate("app" => { "name" => a.name, "release" => rel, "home" => a.dir },
                                         "machines" => a.machines.map { machine_json(_1) }))
      end
      puts "App"
      puts "  Name     = #{a.name}"
      puts "  Release  = #{rel ? "v#{rel['version']} (#{rel['tag']})" : 'none'}"
      puts "  Home     = #{a.dir}"
      puts
      machine_table(a)
    end

    def cmd_releases(_args, o)
      rels = app.meta["releases"]
      return puts(JSON.pretty_generate(rels)) if o[:json]
      return puts("No releases") if rels.empty?
      Util.table(%w[VERSION TAG SOURCE CREATED],
                 rels.reverse.map { ["v#{_1['version']}", _1["tag"], _1["source"], Util.ago(_1["created_at"])] })
    end

    def apps_summary
      App.all.map do |a|
        ms = a.machines
        { "name" => a.name, "machines" => ms.size, "started" => ms.count(&:running?),
          "release" => a.current_release&.dig("version") }
      end
    end

    def apps_list(_args, o)
      reap_exited
      apps = apps_summary
      return puts(JSON.pretty_generate(apps)) if o[:json]
      return puts("No apps") if apps.empty?
      Util.table(%w[NAME MACHINES STARTED RELEASE],
                 apps.map { [_1["name"], _1["machines"], _1["started"], _1["release"] ? "v#{_1['release']}" : "-"] })
    end

    def apps_destroy(args, o)
      name = args.first
      a = App.new(name)
      raise Error, "no app '#{name}'" unless a.exists?
      unless o[:yes]
        raise Error, "no terminal to confirm on; pass --yes to destroy #{name}" unless $stdin.tty?
        print "Destroy #{name}, its #{a.machines.size} machine(s) and #{a.volumes.size} volume(s)? [y/N] "
        return puts("Aborted") unless $stdin.gets.to_s.strip.downcase == "y"
      end
      Util.with_lock { a.machines.each { destroy_machine(_1, force: true) } }
      FileUtils.rm_rf(a.dir)
      puts "Destroyed app #{name}"
    end

    def config_show(_args, _o)
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

    # A machine as list/status/context JSON show it.
    def machine_json(m)
      { "id" => m.id, "name" => m.name, "state" => m.state, "release" => m.release, "ip" => m.ip,
        "cpus" => m.config["cpus"], "memory_mb" => m.config["memory_mb"],
        "internal_port" => m.config["internal_port"], "ports" => Array(m.config["ports"]),
        "volumes" => Array(m.config["mounts"]), "created_at" => m.created_at, "updated_at" => m.updated_at }
    end

    def machine_list(_args, o)
      reap_exited
      return puts(JSON.pretty_generate(app.machines.map { machine_json(_1) })) if o[:json]
      machine_table(app)
    end

    def machine_start(args, _o) = each_ref(args) { |m| boot(m, "Machine #{m.id} [#{m.name}] started") }
    def machine_stop(args, _o) = each_ref(args) { |m| VM.stop(m); puts "Machine #{m.id} [#{m.name}] stopped" }
    def machine_restart(args, _o) = each_ref(args) { |m| VM.stop(m); boot(m, "Machine #{m.id} [#{m.name}] restarted") }
    def machine_destroy(args, o) = Util.with_lock { each_ref(args) { |m| destroy_machine(m, force: o[:force]) } }
    def machine_status(args, _o) = print_json_each(args) { |m| m.h.merge("state" => m.state) }
    def machine_config(args, _o) = print_json_each(args) { |m| VM.spec(m) }

    # One ID: an object. Several: one array, so the output is always one JSON document.
    def print_json_each(refs)
      docs = refs.map { yield app.machine!(_1) }
      puts JSON.pretty_generate(docs.size == 1 ? docs.first : docs)
    end

    def each_ref(argv, &blk) = argv.map { app.machine!(_1) }.each(&blk)

    def scale_count(args, _o)
      raise Error, "N must be a whole number (got '#{args[0]}')" unless args[0].match?(/\A\d+\z/)
      n = args[0].to_i
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
          check_capacity!(a, base, creating: n - ms.size)
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

    def ports_sync(_args, _o)
      reap_exited
      Ports.sync! or raise Error, "port forwarding not applied"
      puts "Port forwarding synced"
    end

    def ports_json
      active, waiting, blocked = Ports.table
      { "helper_installed" => Ports.available?, "min_port" => Ports.min_port,
        "active" => active, "waiting" => waiting, "blocked" => blocked }
    end

    def ports_list(_args, o)
      reap_exited
      return puts(JSON.pretty_generate(ports_json)) if o[:json]
      active, waiting, blocked = Ports.table
      puts Util.yellow("Port helper not installed; run: sudo ./setup-host.sh\n") unless Ports.available?
      return puts("No forwarded ports (add [[services.ports]] to flk.toml)") if [active, waiting, blocked].all?(&:empty?)
      row = ->(r, status) { [r["key"], r["machine"], "#{r['ip']}:#{r['internal_port']}", r["app"], status] }
      Util.table(%w[HOST_PORT MACHINE TARGET APP STATUS],
                 active.map { row[_1, "active"] } + waiting.map { row[_1, "waiting (port taken)"] } +
                 blocked.map { row[_1, "blocked: #{_1['blocked']}"] })
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

    def cmd_console(argv, _o)
      raise Error, "console needs an interactive terminal; for output use: flk logs" unless $stdin.tty? && $stdout.tty?
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

    # ---------- secrets & volumes ----------

    def secrets_list(_args, o)
      rows = app.secrets.map { |k, v| { "name" => k, "digest" => Digest::SHA256.hexdigest(v)[0, 16] } }
      return puts(JSON.pretty_generate(rows)) if o[:json]
      return puts("No secrets") if rows.empty?
      Util.table(%w[NAME DIGEST], rows.map(&:values))
    end

    def secrets_set(args, o)
      update_secrets(o) do |s|
        args.each do |kv|
          k, v = kv.split("=", 2)
          raise Error, "bad secret '#{kv}' (want KEY=VALUE)" if v.nil?
          raise Error, "invalid secret name '#{k}'" unless k.match?(ENV_KEY)
          s[k] = v == "-" ? $stdin.read.chomp : v
        end
      end
    end

    def secrets_import(_args, o)
      update_secrets(o) do |s|
        $stdin.each_line do |l|
          next if l.strip.empty? || l.start_with?("#")
          k, v = l.chomp.split("=", 2)
          raise Error, "bad line: #{l.strip}" unless v && k.match?(ENV_KEY)
          s[k] = v
        end
      end
    end

    def secrets_unset(args, o)
      update_secrets(o) { |s| args.each { |k| s.delete(k) or warn "no secret #{k}" } }
    end

    def update_secrets(o)
      a = app
      s = a.secrets
      yield s
      a.save_secrets(s)
      puts "Secrets updated"
      return puts("Staged; applies on next start/deploy") if o[:stage]
      a.machines.select(&:running?).each do |m|
        VM.stop(m)
        boot(m, "Machine #{m.id} [#{m.name}] restarted with new secrets")
      end
    end

    def volumes_list(_args, o)
      v = app.volumes
      return puts(JSON.pretty_generate(v)) if o[:json]
      return puts("No volumes") if v.empty?
      Util.table(%w[ID NAME SIZE ATTACHED CREATED],
                 v.map { [_1["id"], _1["name"], "#{_1['size_gb']}GB", _1["attached_machine"] || "-", Util.ago(_1["created_at"])] })
    end

    def volumes_create(args, o)
      a = app
      name = args.first
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
    end

    def volumes_destroy(args, _o)
      a = app
      ref = args.first
      Util.with_lock do
        v = a.volume!(ref)
        if v["attached_machine"]
          raise Error, "#{v['id']} is attached to machine #{v['attached_machine']}; destroy that machine first"
        end
        FileUtils.rm_f(v["path"])
        a.save_volumes(a.volumes.reject { _1["id"] == v["id"] })
        puts "Destroyed #{v['id']}"
      end
    end
  end
end
