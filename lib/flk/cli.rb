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
      send(Commands.handler(cmd, sub), argv, opts)
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
    # Everything after "--" is positional (split off here: optparse with
    # require_exact trips over short options past "--"). Commands with
    # passthrough (exec) stop at their first positional, so the command's
    # own options aren't taken for flk's.
    def parse_opts(entry, argv)
      opts = {}
      help = false
      tail = (i = argv.index("--")) ? argv.slice!(i..)[1..] : []
      parser = OptionParser.new do |p|
        p.require_exact = true # no --jso for --json: typos are errors, not guesses
        Array(entry[:opts]).each do |o|
          # a flag is true when given; OptionParser hands "--no-x" flags false
          flag = Commands.switches(o).none? { _1.match?(/[ =]/) }
          p.on(*o) { |v| opts[Commands.key(o)] = flag || v }
        end
        p.on("-h", "--help") { help = true }
      end
      entry[:passthrough] ? parser.order!(argv) : parser.parse!(argv)
      argv.concat(tail)
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

    # ./flk.toml (or fly.toml), unless -a names another app: then the file
    # flk recorded for it at launch/deploy, so -a works from anywhere.
    def config
      @config ||= begin
        here = AppConfig.find
        if @app_name && here&.app != @app_name
          recorded_config(@app_name)
        else
          here || raise(Error, "no flk.toml or fly.toml in #{Dir.pwd} (run: flk launch)")
        end
      end
    end

    def recorded_config(name)
      a = App.new(name)
      path = a.exists? ? a.meta["config_path"] : nil
      unless path
        raise Error, "flk doesn't know where #{name}'s flk.toml is yet; run flk deploy (or flk launch --no-deploy) " \
                     "once in its directory"
      end
      raise Error, "#{name}'s config was at #{path}, which is gone; run flk deploy in its new directory" unless File.exist?(path)
      cfg = AppConfig.new(path)
      raise Error, "#{path} now belongs to app '#{cfg.app}', not #{name}" unless cfg.app == name
      cfg
    end

    # The config for an app if flk can find it (here, or recorded), else nil.
    def config_for(name)
      here = (AppConfig.find rescue nil)
      return here if here&.app == name
      recorded_config(name)
    rescue Error
      nil
    end

    # Remember where the config lives (launch, deploy).
    def record_config_path(a, cfg)
      meta = a.meta
      return if meta["config_path"] == File.expand_path(cfg.path)
      meta["config_path"] = File.expand_path(cfg.path)
      a.save_meta(meta)
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
      if Commands::TOPICS.key?(args[0])
        raise Error, "unexpected argument '#{args[1]}'" if args[1]
        return puts(topic(args[0]))
      end
      cmd = Commands.find(args[0]) or
        raise Error, "unknown command or topic '#{args[0]}'#{hint_for(Commands.suggest(args[0], Commands::LIST + Commands::TOPICS.keys.map { { name: _1 } }))} (see: flk help)"
      sub = args[1] && (Commands.find(args[1], Array(cmd[:subs])) or
                        raise Error, "unknown subcommand 'flk #{cmd[:name]} #{args[1]}' (see: flk help #{cmd[:name]})")
      puts Commands.command_help(cmd, sub)
    end

    def fill(text) = text.gsub("{{VERSION}}", VERSION).gsub("{{ROOT}}", ROOT).gsub("{{SRC}}", File.dirname(SHARE))

    def topic(name) = fill(File.read(File.join(SHARE, "help", "#{name}.md")))

    # share/guide.md with the generated command reference and the topic
    # pages spliced in.
    def guide
      pages = Commands::TOPICS.keys.map { topic(_1).sub(/\A# /, "## Guide: ") }.join("\n")
      fill(File.read(File.join(SHARE, "guide.md")))
          .gsub("{{TOPICS}}", Commands::TOPICS.keys.map { "`flk help #{_1}`" }.join(", "))
          .gsub("{{TOPIC_PAGES}}", pages)
          .gsub("{{COMMANDS}}", Commands.reference_md)
          .gsub("{{JSON_COMMANDS}}", Commands.json_summary)
          .gsub("{{EXIT_CODES}}", Commands::EXIT_CODES.map { |k, v| "- `#{k}`: #{v}" }.join("\n"))
          .gsub("{{MAX_KILL_TIMEOUT}}", AppConfig::MAX_KILL_TIMEOUT.to_s)
          .gsub("{{SCHEMA}}", JSON_SCHEMA.to_s)
          .gsub("{{EVENT_TYPES}}", Events::TYPES.map { |k, v| "- `#{k}`: #{v}" }.join("\n"))
    end

    def cmd_completion(args, _o)
      raise Error, "only bash is supported (zsh: autoload -U bashcompinit && bashcompinit, then the bash script)" unless args[0] == "bash"
      puts Commands.bash_completion
    end

    # "Next: ..." after commands that change things, so nobody has to
    # remember the order. One line, plain, after the result.
    def next_step(*cmds) = puts("Next: #{cmds.join('   or: ')}")

    def cmd_setup(_args, _o)
      Util.sh!(File.join(LIBEXEC, "flk-fetch-assets"))
      puts "==> flk-agent (flk exec): #{Agent.ensure! || 'not built'}"
      puts
      cmd_doctor([], {})
    end

    # --json prints {"ok", "checks": [{"label", "status", "hint"}]} for
    # scripts (flk-sanity.sh). status: pass, fail, or warn (works, but a
    # feature like port forwarding is off). ok is false only on a fail.
    def cmd_doctor(_args, o)
      results = doctor_checks
      ok = results.none? { _1["status"] == "fail" }
      if o[:json]
        return puts(JSON.pretty_generate("schema" => JSON_SCHEMA, "ok" => ok, "checks" => results,
                                         "services" => services_status))
      end
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
            "sudo #{SETUP_HOST} (adds you to kvm group; log out/in)"]
      fc = begin; VM.firecracker_bin; rescue Error; nil; end
      check["firecracker #{fc}", !fc.nil?, "flk setup"]
      check["guest kernel #{VM.kernel}", File.exist?(VM.kernel), "flk setup"]
      check["bridge #{Net::BRIDGE}", Net.bridge_up?, "sudo #{SETUP_HOST}"]
      taps = (0...Net::POOL).count { Net.tap_exists?(_1) }
      check["tap pool #{taps}/#{Net::POOL}", taps.positive?, "sudo #{SETUP_HOST}"]
      fwd = (File.read("/proc/sys/net/ipv4/ip_forward").strip == "1" rescue false)
      check["ipv4 forwarding", fwd, "sudo #{SETUP_HOST}"]
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
      if eng && (orphans = Image.orphan_repos).any?
        record["#{orphans.size} destroyed app#{'s' if orphans.size > 1} still have container images", "warn", "flk apps prune"]
      end
      if eng && Image.podman?(eng)
        old = Image.storage_containers.select { (Time.now - Time.parse(_1[2].to_s) rescue 0) > 3600 }
        if old.any?
          record["#{old.size} build container#{'s' if old.size > 1} left over (interrupted builds?): #{old.map { _1[1] }.join(', ')}",
                 "warn", "if no build is running: #{Image.cleanup_command(old)}"]
        end
      end
      port_helper_check(record)
      boot_service_check(record)
      exit_hook_check(record)
      backup_check(record)
      services_check(record)
      address_check(record)
      huge_pages_check(record)
      agent_check(record)
      results
    end

    # Directories whose disks must be mounted while machines run: flk's
    # state dir and every external volume's. flk-machines.service lists
    # them as RequiresMountsFor= (start after the mounts, stop before them).
    def mount_dirs
      ext = App.all.flat_map(&:volumes).select { App.external_volume?(_1) }.map { File.dirname(_1["path"]) }
      ([ROOT] + ext).uniq
    end

    def boot_unit_mount_dirs = boot_unit_prop("RequiresMountsFor")

    def boot_unit_prop(name, unit = "flk-machines.service")
      out, st = Open3.capture2("systemctl", "show", "-p", name, "--value", unit, err: File::NULL)
      st.success? ? out.split : []
    rescue SystemCallError
      []
    end

    # Why the boot service could start or stop machines without dir's disk,
    # as [problem, fix], or nil when it can't. A mount from /etc/fstab
    # (without nofail) is ordered before local-fs.target, and the service
    # (default dependencies) after it: those need nothing. RequiresMountsFor
    # is for the rest (nofail, network mounts).
    def mount_gap(dir)
      return ["#{dir} is missing: is its disk mounted?", "mount it, then flk doctor"] unless File.directory?(dir)
      return if boot_unit_mount_dirs.include?(dir)
      target, st = Open3.capture2("findmnt", "-n", "-o", "TARGET", "-T", dir, err: File::NULL)
      target = target.strip
      return if !st.success? || target.empty? || target == "/"
      unit = Util.run!("systemd-escape", "-p", "--suffix=mount", target).strip
      before = boot_unit_prop("Before", unit)
      return if before.include?("local-fs.target") || before.include?("flk-machines.service")
      return if before.include?("remote-fs.target") && boot_unit_prop("After").include?("remote-fs.target")
      if boot_unit_prop("SourcePath", unit).empty? && boot_unit_prop("FragmentPath", unit).empty?
        ["#{target} (holding #{dir}) isn't in /etc/fstab: after a reboot it won't be mounted and those machines won't start",
         "add #{target} to /etc/fstab"]
      else
        ["boot service doesn't wait for #{target} (holding #{dir}; nofail or network mount): " \
         "a reboot could start or stop machines without it",
         "sudo #{SETUP_HOST} --install-service (regenerates it)"]
      end
    rescue Error, SystemCallError
      nil # no findmnt/systemd: nothing to check
    end

    # The hook on flk's tmux server must run a flk that exists; a removed
    # checkout (git worktree) leaves it dangling and exits go unnoticed.
    def exit_hook_check(record)
      return if VM.tmux_sessions.empty? # nothing running: the next start installs it
      bin = VM.exit_hook_bin
      if bin.nil?
        record["exit hook missing: machines that exit won't be noticed", "warn", "flk resume (re-installs it)"]
      elsif !File.executable?(bin)
        record["exit hook runs #{bin}, which is gone", "warn", "flk resume (re-installs it)"]
      elsif bin != VM.hook_bin
        record["exit hook runs #{bin}, not #{VM.hook_bin} (the boot service's flk)", "warn",
               "#{VM.hook_bin} resume (re-installs it)"]
      else
        record["exit hook (#{bin})", "pass", nil]
      end
    end

    # The host address setting and every bind address in use should be on
    # this host; one that isn't answers nothing (fine for a floating
    # address another host holds right now, so only a warn).
    def address_check(record)
      s = Host.settings
      local = Net.local_addresses
      wanted = s["address"] ? { s["address"] => "address in #{Host::PATH}" } : {}
      ps = Host.port_settings
      Array(ps["bind"]).each { wanted[_1] ||= "bind in #{Host::HOST_FILE}" }
      App.all.each do |a|
        a.machines.each { |m| Array(m.config["bind"]).each { wanted[_1] ||= "[flk] bind of #{a.name}" } }
      end
      wanted.delete("all")
      bound = (Array(ps["bind"]) - ["all"]).any? ||
              App.all.any? { |a| a.machines.any? { (Array(_1.config["bind"]) - ["all"]).any? } }
      if bound && Ports.available? && !Ports.per_address?
        record["bind is set, but the port helper predates it: ports still answer on every host address", "warn",
               "sudo #{SETUP_HOST}"]
      end
      wanted.each do |addr, why|
        if local.include?(addr)
          record["#{addr} (#{why}) is on this host", "pass", nil]
        else
          record["#{addr} (#{why}) isn't on this host: nothing answers there", "warn",
                 "add it to the interface (netplan), or ignore while another host holds it (floating address)"]
        end
      end
    rescue Error => e
      record[e.message, "warn", "fix #{Host::PATH}"]
    end

    # Only when some machine uses a 2M pool: will the ones that aren't
    # running fit when they start (after a reboot, say)?
    def huge_pages_check(record)
      ms = App.all.flat_map(&:machines).select { _1.config["huge_pages"] == "2M" }
      return if ms.empty?
      pool = VM.huge_pool
      waiting = ms.reject(&:running?).select { _1.desired_state == "started" }.sum { VM.huge_pages_needed(_1.config) }
      label = "huge pages: #{pool[:available]} of #{pool[:total]} (2M) free for #{ms.size} machine#{'s' if ms.size > 1} using them"
      if (why = VM.huge_pages_short(waiting, pool[:available]))
        record["#{label}; machines that should run #{why.lines.first.strip}", "warn", why.lines[1..].map(&:strip).first(2).join(" && ")]
      else
        record[label, "pass", nil]
      end
    end

    FLK_UNITS = %w[flk-net.service flk-machines.service].freeze

    # flk's systemd units as systemd sees them (no root needed). Units that
    # aren't installed have installed: false and nothing else to say.
    def services_status
      @services_status ||= FLK_UNITS.map do |u|
        out, st = Open3.capture2("systemctl", "show", u, "--timestamp=unix",
                                 "-p", "LoadState,UnitFileState,ActiveState,SubState,Result,StateChangeTimestamp",
                                 err: File::NULL)
        h = st.success? ? out.lines.to_h { _1.chomp.split("=", 2) } : {}
        since = h["StateChangeTimestamp"].to_s[/\A@(\d+)/, 1]
        { "unit" => u, "installed" => h["LoadState"] == "loaded", "enabled" => h["UnitFileState"] == "enabled",
          "active" => h["ActiveState"], "sub" => h["SubState"], "result" => h["Result"],
          "since" => since && Time.at(since.to_i).utc.iso8601 }
      end
    rescue SystemCallError
      @services_status = []
    end

    # A failed unit is worth a look; one that isn't installed is covered by
    # boot_service_check (and setup-host.sh).
    def services_check(record)
      services_status.select { _1["installed"] && _1["active"] == "failed" }.each do |s|
        record["#{s['unit']} failed (#{s['result']}) #{Util.ago(s['since']) if s['since']}".strip, "warn",
               "journalctl -u #{s['unit']} -b, then sudo systemctl restart #{s['unit']}"]
      end
    end

    # Only when some app has volumes: where `flk volumes backup` copies to.
    def backup_check(record)
      dir = Host.settings["backup_dir"]
      if dir.nil?
        return unless App.all.any? { _1.volumes.any? }
        record["no backup_dir set: flk volumes backup needs --to DIR", "warn",
               "add backup_dir = \"/path\" to #{Host::PATH}"]
      elsif !File.directory?(dir) || !File.writable?(dir)
        record["backup_dir #{dir} is missing or not writable (disk not mounted?)", "warn", "mount it, or fix #{Host::PATH}"]
      else
        backup_space_check(record, dir)
        backup_copy_check(record, dir)
      end
    rescue Error => e
      record[e.message, "warn", "fix #{Host::PATH}"]
    end

    # Will `keep` backups of every volume that has backups fit? Each takes
    # about its volume's used space; they can have the free space plus
    # what flk's backups there take now.
    def backup_space_check(record, root)
      free = Backup.free_bytes(root)
      host_keep = Backup.keep(nil)
      now = 0
      steady = App.all.sum do |a|
        keep = ((config_for(a.name)&.backup || {})["keep"] rescue nil) || host_keep
        a.volumes.sum do |v|
          bs = Backup.list(root, a.name, v)
          now += bs.sum { _1["bytes_used"] }
          bs.empty? || !File.exist?(v["path"].to_s) ? 0 : keep * Backup.used_bytes(v["path"])
        end
      end
      room = free + now
      fs = fs_type(root)
      label = "backups go to #{root}: #{Backup.gb(now)} now, about #{Backup.gb(steady)} at their keep counts; " \
              "#{Backup.gb(free)} free; #{%w[xfs btrfs].include?(fs) ? "#{fs}: copies of volumes on it are instant" : "full copies (#{fs || '?'} has no reflinks)"}"
      if steady > room * 0.9
        record["#{label}: that's tight (#{(100.0 * steady / room).round}% of #{Backup.gb(room)})", "warn",
               "lower backup_keep / [flk.backup] keep, or give #{root} more space"]
      else
        record[label, "pass", nil]
      end
    end

    # With backup_copy_to: is every backed-up volume's newest copy recent?
    def backup_copy_check(record, root)
      dest = Host.settings["backup_copy_to"] or return
      days = (Host.settings["backup_copy_warn_days"] || 8).to_f
      stale = App.all.flat_map do |a|
        a.volumes.filter_map do |v|
          bs = Backup.list(root, a.name, v)
          next if bs.empty?
          t = Backup.newest_copy(bs, Backup.remote?(dest) ? dest : File.expand_path(dest))
          "#{a.name}/#{v['name']} (#{t ? "newest copy #{Util.ago(t.utc.iso8601)}" : 'never copied'})" if t.nil? || Time.now - t > days * 86_400
        end
      end
      if stale.any?
        record["backup copies to #{dest} are missing or older than #{days.to_i} days: #{stale.join(', ')}", "warn",
               "flk -a APP volumes copy (and check that backups run: flk -a APP volumes backups)"]
      else
        record["backups are copied to #{dest}", "pass", nil]
      end
    end

    # Optional: flk exec / ssh console need the agent in new releases.
    def agent_check(record)
      if File.exist?(Agent.path) && !Agent.stale?
        record["flk-agent built (flk exec in releases deployed from now on)", "pass", nil]
      elsif Agent.go
        record["flk-agent #{File.exist?(Agent.path) ? 'is older than its source' : 'not built yet'} (built at the next deploy)", "pass", nil]
      else
        record["no flk-agent and no Go to build it: releases get no flk exec / flk ssh console", "warn",
               "install Go (or set FLK_GO), then flk setup"]
      end
    end

    # Optional: without it nothing comes back after a reboot.
    def boot_service_check(record)
      unit = "/etc/systemd/system/flk-machines.service"
      ok = File.exist?(unit) && system("systemctl", "is-enabled", "--quiet", "flk-machines.service", err: File::NULL)
      fix = "sudo #{SETUP_HOST} --install-service"
      if !ok
        record["boot service: after a reboot the network and machines stay down", "warn", fix]
      elsif (gaps = mount_dirs.filter_map { mount_gap(_1) }).any?
        gaps.each { |problem, how| record[problem, "warn", how] }
      else
        record["boot service (machines come back after a reboot)", "pass", nil]
      end
    rescue SystemCallError
      record["boot service: systemctl not found", "warn", "after a reboot: sudo #{SETUP_HOST} && flk resume"]
    end

    # Optional: without it machines run, but [[services.ports]] isn't forwarded.
    def port_helper_check(record)
      fix = "sudo #{SETUP_HOST}"
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
      c = o[:all] ? host_context(no_host: o[:no_host]) : context(no_host: o[:no_host])
      return puts(JSON.pretty_generate(c)) if o[:json]
      puts(o[:all] ? host_context_text(c) : context_text(c))
    end

    # Every app at once: what's running where, what's reachable, what's wrong.
    def host_context(no_host: false)
      host = no_host ? [] : doctor_checks
      steps = host.reject { _1["status"] == "pass" }
                  .map { "#{_1['status'] == 'fail' ? 'fix' : 'optional'}: #{_1['label']} -> #{_1['hint']}" }
      apps = App.all.map do |a|
        app_steps = []
        cfg = config_for(a.name)
        h = app_context(a, cfg, app_steps)
        steps.concat(app_steps.reject { _1.start_with?("all good") }.map { "#{a.name}: #{_1}" })
        h
      end
      { "schema" => JSON_SCHEMA,
        "flk" => { "version" => VERSION, "state_dir" => ROOT, "source" => File.dirname(SHARE) },
        "mount_dirs" => mount_dirs,
        "host" => if no_host
                    { "lan_ip" => Net.host_lan_ip, "address" => Net.host_address }
                  else
                    { "ok" => host.none? { _1["status"] == "fail" }, "problems" => host.reject { _1["status"] == "pass" },
                      "lan_ip" => Net.host_lan_ip, "address" => Net.host_address, "boot_service" => host.any? { _1["label"].start_with?("boot service (") },
                      "services" => services_status }
                  end,
        "apps" => apps, "next_steps" => steps }
    end

    def host_context_text(c)
      h = c["host"]
      health = if h.key?("ok")
                 "#{h['ok'] ? 'ready' : 'NOT ready'}, address #{h['address'] || h['lan_ip'] || '?'}, " \
                   "boot service #{h['boot_service'] ? 'installed' : 'missing'}"
               else
                 "not checked (--no-host), address #{h['address'] || h['lan_ip'] || '?'}"
               end
      out = ["# flk host overview", "",
             "flk #{c['flk']['version']}  state: #{c['flk']['state_dir']}  source: #{c['flk']['source']}",
             "host: #{health}", ""]
      return (out << "No apps. Start with: flk help first-app").join("\n") if c["apps"].empty?
      c["apps"].each do |a|
        ms = Array(a["machines"])
        rel = a["release"]
        out << "## #{a['name']}  (#{rel ? "v#{rel['version']}" : 'no release'}, #{ms.count { _1['state'] == 'started' }}/#{ms.size} started)"
        ms.each do |m|
          flag = m["state"] != "started" && m["desired_state"] == "started" ? "  <- should be running" : ""
          out << "  #{m['id']} [#{m['name']}] #{m['state']} #{m['ip']}#{m['internal_port'] ? ":#{m['internal_port']}" : ''}#{flag}"
        end
        Array(a["config_warnings"]).each { out << "  ⚠ #{File.basename(a['config_path'] || 'flk.toml')}: #{_1}" }
        Array(a.dig("ports", "active")).each { out << "  port #{Ports.label(_1)} -> #{_1['address'] || "LAN IP:#{_1['port']}"}" }
        Array(a.dig("ports", "blocked")).each { out << "  port #{_1['key']} blocked: #{_1['blocked']}" }
        vols = Array(a["volumes"])
        out << "  volumes: #{vols.map { "#{_1['name']} #{_1['size_gb']}GB#{' (external)' if _1['external']}" }.join(', ')}" if vols.any?
        out << ""
      end
      out << "## Needs attention"
      c["next_steps"].each { out << "- #{_1}" }
      out << "- nothing" if c["next_steps"].empty?
      out << "" << "Details for one app: flk context -a APP.  Commands by task: flk help cheatsheet"
      out.join("\n")
    end

    # Everything an agent (or a person) needs to pick the next command,
    # gathered without failing: problems become next_steps.
    def context(no_host: false)
      host = no_host ? [] : doctor_checks
      c = { "schema" => JSON_SCHEMA,
            "flk" => { "version" => VERSION, "state_dir" => ROOT, "source" => File.dirname(SHARE),
                       "reference" => "flk help --all" },
            "host" => if no_host
                        { "lan_ip" => Net.host_lan_ip, "address" => Net.host_address }
                      else
                        { "ok" => host.none? { _1["status"] == "fail" }, "problems" => host.reject { _1["status"] == "pass" } }
                      end,
            "cwd" => Dir.pwd, "config" => nil, "app" => nil, "other_apps" => [], "next_steps" => [] }
      steps = c["next_steps"]
      Array(c["host"]["problems"]).each { steps << "#{_1['status'] == 'fail' ? 'fix' : 'optional'}: #{_1['label']} -> #{_1['hint']}" }

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
        c["app"] = app_context(App.new(name), cfg&.app == name ? cfg : config_for(name), steps)
      elsif !c["config"]
        steps << "no flk.toml or fly.toml in #{Dir.pwd}: cd to an app directory, pass -a APP, or create one with: flk launch"
      end
      c["other_apps"] = apps_summary.reject { _1["name"] == name }
      c
    end

    def app_context(a, cfg, steps)
      h = { "name" => a.name, "registered" => a.exists?, "config_warnings" => warning_strings(cfg) }
      unless a.exists?
        steps << (cfg ? "register the app: flk launch --no-deploy (then flk deploy)" : "app '#{a.name}' doesn't exist; see: flk apps list")
        return h
      end
      h["config_warnings"].each { steps << "optional: #{File.basename(cfg.path)}: #{_1}" }
      ms = a.machines
      rel = a.current_release
      h.merge!("home" => a.dir, "config_path" => a.meta["config_path"],
               "release" => rel, "releases" => a.meta["releases"].size, "scale" => a.meta["scale"],
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
      unless a.meta["config_path"]
        steps << "flk doesn't know where #{a.name}'s flk.toml is: run flk launch --no-deploy (or flk deploy) once in its directory"
      end
      if rel.nil?
        steps << (cfg ? "deploy the first release: flk deploy" : "no release yet; run flk deploy from the app directory")
      elsif ms.empty?
        steps << "no machines; flk deploy (or flk scale count 1)"
      end
      ms.reject(&:running?).each do |m|
        steps << if m.h.dig("restarts", "gave_up_at")
                   "machine #{m.id} [#{m.name}] kept failing; its restart policy gave up after " \
                   "#{m.h.dig('restarts', 'count')} restarts: flk logs -i #{m.id} --no-tail, fix, then flk machine start #{m.id}"
                 elsif m.desired_state == "started"
                   "machine #{m.id} [#{m.name}] should be running but isn't (it exited, or the host restarted); " \
                   "see why: flk logs -i #{m.id} --no-tail; bring it back: flk resume"
                 else
                   "machine #{m.id} [#{m.name}] is stopped; start it: flk machine start #{m.id}"
                 end
      end
      h["ports"]["blocked"].each { steps << "host port #{_1['key']} not forwarded: #{_1['blocked']}" }
      h["ports"]["waiting"].each { steps << "host port #{_1['key']} is held by another machine; this one gets it when that stops" }
      if rel && rel["version"]
        # newer than current = a failed release that deploy --no-rollback left running
        failed, other = ms.partition { stranded_on_failed?(a, _1, rel) }
        failed.each do |m|
          steps << "machine #{m.id} [#{m.name}] is on v#{m.release}, which failed its health checks (left by --no-rollback): " \
                   "see flk logs -i #{m.id} --no-tail; then flk releases rollback v#{rel['version']}, or fix and flk deploy"
        end
        steps << "some machines run an older release; flk deploy rolls them" if cfg && other.any? { _1.release != rel["version"] }
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
             "## Host", c["host"].key?("ok") ? (c["host"]["ok"] ? "ready" : "NOT ready") : "not checked (--no-host)"]
      Array(c["host"]["problems"]).each { out << "- #{_1['status']}: #{_1['label']} -> #{_1['hint']}" }
      out << "" << "## App" << "cwd: #{c['cwd']}"
      if (cf = c["config"])
        out << "config: #{cf['file'] || '(unreadable)'}#{" -- ERROR: #{cf['error']}" if cf['error']}"
      else
        out << "config: none in this directory"
      end
      if (a = c["app"])
        out << "app: #{a['name']}#{' (not registered)' unless a['registered']}"
        Array(a["config_warnings"]).each { out << "⚠ #{File.basename(a['config_path'] || 'flk.toml')}: #{_1}" }
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
          rows = ports["active"].map { "#{Ports.label(_1)} -> #{_1['ip']}:#{_1['internal_port']} (active; connect to #{_1['address'] || "host LAN IP:#{_1['port']}"}, not 127.0.0.1)" } +
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
      record_config_path(a, AppConfig.find)

      cfg = config
      buildable = cfg.image || File.exist?(File.expand_path(cfg.dockerfile, cfg.dir))
      if o[:no_deploy] || !buildable
        puts "No Dockerfile or [build] image yet." unless buildable
        next_step("edit flk.toml (flk help first-app)", "flk deploy")
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

        # [[restart]]
        #   policy = "on-failure"  # default: restart after a crash; "always" or "never"

        # [flk]
        #   http_port = 8080       # also serve internal_port on host port 8080 (LAN too)
      TOML
    end

    def cmd_deploy(_args, o)
      cfg = config
      if @app_name && @app_name != cfg.app
        raise Error, "-a #{@app_name} doesn't match app '#{cfg.app}' in #{File.basename(cfg.path)}"
      end
      a = App.new(cfg.app)
      a.create! unless a.exists?
      config_warnings(cfg)
      mconfig = cfg.machine_config

      deploy_capacity!(a, mconfig) # before the slow build
      pre = pre_deploy_backup(a, cfg)
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
          meta["config_path"] = File.expand_path(cfg.path)
          a.save_meta(meta)
          recorded = true
          roll!(a, rel, mconfig, machines, no_rollback: o[:no_rollback], pre_backup: pre)
        end
      ensure
        unless recorded
          FileUtils.rm_f(File.join(a.dir, "images", "v#{version}.ext4"))
          Image.untag(a.name) { _1 == "v#{version}" }
        end
      end
      Image.prune(a, keep: cfg.keep_releases)

      puts Util.green("\n✔ Deployed #{a.name} v#{version}")
      if (port = mconfig["internal_port"])
        a.machines.each { |m| puts "   #{m.name}  http://#{m.ip}:#{port}" }
      end
      next_step("flk status", "flk logs", "flk context")
    end

    # The same warnings as strings, for JSON ([] without a readable config).
    def warning_strings(cfg)
      return [] unless cfg
      cfg.unknown_keys.map { "unknown key #{_1}; flk ignores it" }
    rescue StandardError
      []
    end

    # Warnings about the config that don't stop anything: unknown keys.
    def config_warnings(cfg)
      cfg.unknown_keys.each do |k|
        warn Util.yellow("⚠ #{File.basename(cfg.path)}: unknown key #{k}; flk ignores it")
      end
    end

    # Puts every machine of the app on rel: creates them on a first deploy,
    # else stops, updates and boots each in turn. With health checks, a
    # machine that fails them stops the roll: it goes back to the release
    # and config it had (unless no_rollback), the release is marked failed,
    # and machines not reached yet are left as they were.
    # [flk.backup] before_deploy: where and how a deploy backs up each
    # machine's volumes while it's stopped for the update (nil: off).
    def pre_deploy_backup(a, cfg, force: false)
      plan = cfg ? cfg.backup : DEFAULT_BACKUP
      return nil unless plan["before_deploy"] || force
      return nil if a.volumes.none? { _1["attached_machine"] }
      { root: Backup.root!(nil), plan: plan, keep: Backup.keep(plan["keep"]), hook_dir: cfg&.dir || Dir.pwd }
    end

    # Backs up the volumes attached to m (stopped) for a roll to rel;
    # returns [{ machine, volume, volume_id, file, path }].
    def backup_before_deploy(m, rel, pre)
      m.app.volumes.select { _1["attached_machine"] == m.id }.map do |v|
        dst = backup_one(m.app, v, pre[:root], pre[:plan], pre[:keep], pre[:hook_dir], check: true, fast: true,
                         extra: { "reason" => "before_deploy", "release" => m.release, "for_release" => rel["version"] })
        { "machine" => m.id, "volume" => v["name"], "volume_id" => v["id"], "file" => File.basename(dst), "path" => dst }
      end
    end

    # Puts each of m's volumes (machine stopped) back from a backup:
    # { volume_id => backup path }.
    def restore_volumes(m, from)
      from.each do |vid, path|
        v = m.app.volumes.find { _1["id"] == vid } or next
        puts "  #{m.id} [#{m.name}] volume #{v['name']} <- #{File.basename(path)}"
        Backup.restore_over(path, v["path"])
        Events.machine("volume.restored", m, "#{v['name']} from #{File.basename(path)}")
      end
    end

    def record_release_backups(a, rel, taken)
      meta = a.meta
      r = meta["releases"].find { _1["version"] == rel["version"] } or return
      r["backups"] = Array(r["backups"]) + taken.map { _1.except("path") }
      a.save_meta(meta)
    end

    def roll!(a, rel, mconfig, machines, **kw)
      what = rel["rollback_of"] ? "rollback to v#{rel['rollback_of']}" : "deploy"
      Events.emit("deploy.started", app: a.name, release: rel["version"],
                                    detail: "#{what}, #{machines.empty? ? 'new machines' : "#{machines.size} machine#{'s' if machines.size > 1}"}")
      roll_machines!(a, rel, mconfig, machines, **kw)
      Events.emit("deploy.succeeded", app: a.name, release: rel["version"], detail: what)
    rescue Error => e
      Events.emit("deploy.failed", app: a.name, release: rel["version"], detail: e.message)
      raise
    end

    def roll_machines!(a, rel, mconfig, machines, no_rollback: false, pre_backup: nil, restore: {})
      checks = Array(mconfig["checks"])
      if machines.empty?
        count = [a.meta["scale"] || 1, 1].max
        puts "==> Creating #{count} machine#{'s' if count > 1}"
        count.times do
          m = create_machine(a, rel, mconfig)
          next if (why = health_failure(m, checks)).nil?
          fail_release!(a, rel, why)
          raise Error, "v#{rel['version']} failed its health checks on new machine #{m.id}: #{why}. " \
                       "Nothing older to go back to; fix it and deploy again (logs: flk logs -i #{m.id} --no-tail)"
        end
        return
      end
      puts "==> Updating #{machines.size} machine#{'s' if machines.size > 1} (rolling)"
      done = []
      machines.each do |m|
        before = { "release" => m.release, "config" => m.h["config"] }
        taken = []
        update_machine(m, rel, mconfig) do
          if pre_backup
            taken = backup_before_deploy(m, rel, pre_backup)
            record_release_backups(a, rel, taken)
          end
          restore_volumes(m, restore[m.id] || {})
        end
        if (why = health_failure(m, checks)).nil?
          done << m
          next
        end
        fail_release!(a, rel, why)
        back = rollback_machine(m, before, volumes: taken.to_h { [_1["volume_id"], _1["path"]] }) unless no_rollback
        msg = "v#{rel['version']} failed its health checks on #{m.id} [#{m.name}]: #{why}. " +
              (back ? "#{m.id} is back on v#{before['release']}#{' with its volumes as they were' if taken.any?}" : "#{m.id} was left on v#{rel['version']} (logs: flk logs -i #{m.id} --no-tail)")
        msg += "; #{done.map(&:id).join(', ')} already moved to v#{rel['version']} (back: flk releases rollback)" if done.any?
        rest = machines.size - done.size - 1
        msg += "; #{rest} machine#{'s' if rest > 1} not touched" if rest.positive?
        raise Error, msg
      end
    end

    def fail_release!(a, rel, why)
      meta = a.meta
      r = meta["releases"].find { _1["version"] == rel["version"] }
      r.merge!("status" => "failed", "failure" => why, "failed_at" => Util.now)
      a.save_meta(meta)
    end

    # Back to the release and config a machine had before an update.
    # With volumes ({ volume_id => backup path }, from before_deploy), the
    # volumes go back too.
    def rollback_machine(m, before, volumes: {})
      old = m.app.release(before["release"])
      unless old && File.exist?(old["path"].to_s)
        warn Util.yellow("  can't put #{m.id} back: v#{before['release']}'s image is gone")
        return false
      end
      puts "  #{m.id} [#{m.name}] going back to v#{old['version']}"
      VM.stop(m)
      restore_volumes(m, volumes)
      m.h["release"] = old["version"]
      m.h["config"] = before["config"]
      m.save!
      install_rootfs(m, old)
      boot(m, "Machine #{m.id} [#{m.name}] back on v#{old['version']}", event: "machine.rolled_back")
      true
    rescue Error => e
      warn Util.red("  couldn't put #{m.id} back on v#{before['release']}: #{e.message}")
      false
    end

    # nil when every check passes within its grace_period, else why not.
    def health_failure(m, checks)
      checks.each do |c|
        what = c["type"] == "log" ? "log /#{c['match']}/" : "#{c['type']} :#{c['port']}#{c['path']}"
        print "    check #{c['name']} (#{what}, up to #{c['grace_period']}s) "
        $stdout.flush
        t0 = Time.now
        passed = Util.wait_for(c["grace_period"], 1) do
          unless m.running?
            puts Util.red("✘")
            Events.machine("check.failed", m, "#{c['name']}: the machine exited")
            return "machine #{m.id} exited (flk logs -i #{m.id} --no-tail)"
          end
          check_passes?(m, c)
        end
        unless passed
          puts Util.red("✘")
          Events.machine("check.failed", m, "#{c['name']} (#{what}) didn't pass within #{c['grace_period']}s")
          return "check #{c['name']} (#{what}) didn't pass within #{c['grace_period']}s"
        end
        Events.machine("check.passed", m, "#{c['name']} (#{what}) in #{(Time.now - t0).round}s")
        puts "#{Util.green('✔')} #{(Time.now - t0).round}s"
      end
      nil
    end

    def check_passes?(m, c)
      case c["type"]
      when "tcp"
        Socket.tcp(m.ip, c["port"], connect_timeout: 2) { true }
      when "http"
        res = Net::HTTP.start(m.ip, c["port"], open_timeout: 2, read_timeout: 5) { _1.get(c["path"]) }
        res.code.to_i.between?(200, 399)
      when "log"
        log = m.path("console.log")
        tail = File.open(log, "rb") { |f| f.seek([f.size - 262_144, 0].max); f.read }.to_s
        since = tail.rindex("--- flk: booting") || 0
        tail[since..].scrub.match?(Regexp.new(c["match"]))
      end
    rescue SystemCallError, IOError, Net::OpenTimeout, Net::ReadTimeout, Net::HTTPBadResponse, EOFError
      false
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
      # huge pages: machines are updated one at a time, and the one being
      # updated gives its pages back first
      if (per = VM.huge_pages_needed(mconfig)).positive?
        back = updating.select(&:running?).map { VM.huge_pages_needed(_1.config) }.max.to_i
        need = creating.positive? ? per * creating : per
        if (why = VM.huge_pages_short(need, VM.huge_pool[:available] + (creating.positive? ? 0 : back)))
          raise Error, "[[vm]] huge_pages = \"2M\": #{a.name} #{why}"
        end
      end
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
                   "re-run: sudo FLK_TAPS=#{Net::POOL * 2} #{SETUP_HOST}"
    end

    # Every listing command tidies machines that exited on their own, so the
    # host port map follows them (ports are global, hence all apps).
    def reap_exited(wait: false) = VM.reap(App.all.flat_map(&:machines), wait: wait)

    def cmd_status(_args, o)
      reap_exited
      a = app
      rel = a.current_release
      if o[:json]
        return puts(JSON.pretty_generate("app" => { "name" => a.name, "release" => rel, "home" => a.dir,
                                                    "config_path" => a.meta["config_path"] },
                                         "machines" => a.machines.map { machine_json(_1) }))
      end
      puts "App"
      puts "  Name     = #{a.name}"
      puts "  Release  = #{rel ? "v#{rel['version']} (#{rel['tag']})" : 'none'}"
      puts "  Home     = #{a.dir}"
      puts "  Config   = #{a.meta['config_path'] || 'unknown (run flk deploy in the app directory once)'}"
      puts
      machine_table(a)
    end

    def releases_list(_args, o)
      a = app
      rels = a.meta["releases"]
      cur = a.current_release&.dig("version")
      on = a.machines.map(&:release)
      rows = rels.map do |r|
        r.reject { |k, _| k == "config" }.merge("current" => r["version"] == cur, "image" => File.exist?(r["path"].to_s),
                                              "machines" => on.count(r["version"]))
      end
      return puts(JSON.pretty_generate(rows)) if o[:json]
      return puts("No releases") if rows.empty?
      Util.table(%w[VERSION STATUS MACHINES SOURCE CREATED], rows.reverse.map do |r|
        status = if r["status"] == "failed" then "failed: #{r['failure']}"
                 elsif r["current"] then "current"
                 elsif r["image"] then "kept (flk releases rollback v#{r['version']})"
                 else "image pruned"
                 end
        ["v#{r['version']}", status, r["machines"], r["source"], Util.ago(r["created_at"])]
      end)
    end

    # A new release with an older one's image and machine config, rolled
    # out like a deploy (health checks included).
    def releases_rollback(args, o)
      raise Error, "rollback takes at most one release (e.g. v3)" if args.size > 1
      a = app
      cur = a.current_release or raise Error, "#{a.name} has no release yet"
      # machines a deploy --no-rollback left on a failed release: back to current
      stranded = a.machines.select { stranded_on_failed?(a, _1, cur) }
      target = if args[0]
                 v = args[0].delete_prefix("v")
                 raise Error, "'#{args[0]}' isn't a release (e.g. v3)" unless v.match?(/\A\d+\z/)
                 a.release(v.to_i) or raise Error, "#{a.name} has no release v#{v} (see: flk releases)"
               elsif stranded.any?
                 cur
               else
                 a.meta["releases"].reverse.find { _1["version"] < cur["version"] && _1["status"] != "failed" } or
                   raise Error, "no release before v#{cur['version']} to go back to"
               end
      raise Error, "v#{target['version']} is already the current release" if target["version"] == cur["version"] && stranded.empty?
      raise Error, "v#{target['version']} failed its health checks; pick another (flk releases)" if target["status"] == "failed"
      unless File.exist?(target["path"].to_s)
        kept = a.meta["releases"].select { File.exist?(_1["path"].to_s) }.map { "v#{_1['version']}" }
        raise Error, "v#{target['version']}'s image was pruned; releases with images: #{kept.join(', ')} " \
                     "(keep more with [flk] keep_releases)"
      end
      mconfig = target["config"]
      unless mconfig
        cfg = config_for(a.name) or raise Error, "v#{target['version']} predates recorded configs and flk can't find #{a.name}'s flk.toml"
        mconfig = cfg.machine_config
        warn Util.yellow("⚠ v#{target['version']} predates recorded configs: using #{cfg.path} as it is now")
      end
      cfg = config_for(a.name)
      restore = o[:with_volumes] ? volumes_of_release!(a, target) : {}
      pre = pre_deploy_backup(a, cfg, force: o[:with_volumes])
      Util.with_lock do
        machines = deploy_capacity!(a, mconfig)
        meta = a.meta
        version = meta["releases"].last["version"] + 1
        puts "==> Release v#{version} of #{a.name}: rollback to v#{target['version']}#{' with volumes' if o[:with_volumes]}"
        path = File.join(a.dir, "images", "v#{version}.ext4")
        Util.run!("cp", "--reflink=auto", "--sparse=always", target["path"], path)
        tag = "#{Image.repo(a.name)}:v#{version}"
        system(Image.engine, "tag", target["tag"], tag, out: File::NULL, err: File::NULL) rescue nil
        rel = { "version" => version, "tag" => tag, "path" => path, "source" => "rollback to v#{target['version']}",
                "rollback_of" => target["version"], "created_at" => Util.now, "config" => mconfig }
        meta["releases"] << rel
        a.save_meta(meta)
        roll!(a, rel, mconfig, machines, no_rollback: o[:no_rollback], pre_backup: pre, restore: restore)
      end
      Image.prune(a, keep: (config_for(a.name)&.keep_releases || 2))
      puts Util.green("\n✔ #{a.name} is on v#{a.current_release['version']} (the image and config of v#{target['version']})")
      next_step("flk status", "flk releases")
    end

    # For rollback --with-volumes: { machine id => { volume id => backup
    # path } }, the newest before_deploy backup of each attached volume
    # taken while leaving target (its machine was on target then).
    def volumes_of_release!(a, target)
      root = Backup.root!(nil)
      missing = []
      out = a.machines.to_h do |m|
        vols = a.volumes.select { _1["attached_machine"] == m.id }
        [m.id, vols.to_h do |v|
          b = Backup.list(root, a.name, v).find do
            _1["reason"] == "before_deploy" && _1["release"] == target["version"] && _1["volume_id"] == v["id"]
          end
          missing << "#{v['name']} (machine #{m.id})" unless b
          [v["id"], b&.dig("path")]
        end]
      end
      if missing.any?
        raise Error, "no before-deploy backup from v#{target['version']} of: #{missing.join(', ')} " \
                     "(they're taken by deploys with [flk.backup] before_deploy = true, and pruned by keep; see flk volumes backups)"
      end
      out
    end

    # Is m on a failed release newer than cur (left there by deploy --no-rollback)?
    def stranded_on_failed?(a, m, cur)
      m.release.to_i > cur["version"] && a.release(m.release)&.dig("status") == "failed"
    end

    def apps_summary
      App.all.map do |a|
        ms = a.machines
        { "name" => a.name, "machines" => ms.size, "started" => ms.count(&:running?),
          "release" => a.current_release&.dig("version"), "config_path" => a.meta["config_path"] }
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
      kept = a.volumes.select { App.external_volume?(_1) }
      Util.with_lock { a.machines.each { destroy_machine(_1, force: true) } }
      FileUtils.rm_rf(a.dir) # external volume files live outside it
      Image.untag(name)
      puts "Destroyed app #{name}"
      kept.each { puts "  kept external volume #{_1['name']} (#{_1['id']}): #{_1['path']}" }
      root = (Backup.root!(nil) rescue nil)
      bdir = root && File.join(root, name)
      return unless bdir && File.directory?(bdir)
      if o[:with_backups]
        delete_backups!(bdir)
        puts "  deleted its backups in #{bdir}"
      else
        puts "  kept its backups in #{bdir} (#{Backup.gb(du_tree(bdir)['bytes'])}); delete them with: flk apps prune --backups"
      end
    end

    def apps_prune(_args, o)
      names = Image.orphan_repos
      if names.any?
        n = names.sum { Image.untag(_1) }
        puts "Removed #{n} image tag#{'s' unless n == 1} of #{names.size} destroyed app#{'s' unless names.size == 1}: #{names.join(', ')}"
      end
      root = o[:backups] || o[:to] ? Backup.root!(o[:to]) : (Backup.root!(nil) rescue nil)
      gone = root ? gone_backup_dirs(root) : []
      if gone.any? && o[:backups]
        gone.each do |d|
          size = Backup.gb(du_tree(d)["bytes"])
          delete_backups!(d)
          puts "Deleted backups of destroyed app #{File.basename(d)} (#{size}): #{d}"
        end
      elsif gone.any?
        puts "#{gone.size} destroyed app#{'s' if gone.size > 1} still #{gone.size > 1 ? 'have' : 'has'} backups in #{root}: " \
             "#{gone.map { File.basename(_1) }.join(', ')} (flk apps prune --backups deletes them)"
      end
      puts "Nothing to prune" if names.empty? && gone.empty?
    end

    # Per-app dirs in a backup root whose app is gone and that hold only
    # flk's backup files (anything else there: left alone).
    def gone_backup_dirs(root)
      Dir.children(root).sort.filter_map do |n|
        d = File.join(root, n)
        next unless File.directory?(d) && App::NAME_RE.match?(n) && !App.new(n).exists?
        d if backup_files_only?(d)
      end
    end

    BACKUP_FILE_RE = /\A[a-z0-9_]+-\d{8}T\d{6}Z\.(?:ext4|json|fsck\.log|verify\.log|ext4\.partial)\z/

    def backup_files_only?(dir)
      Dir.children(dir).all? do |vol|
        vd = File.join(dir, vol)
        File.directory?(vd) && Dir.children(vd).all? { BACKUP_FILE_RE.match?(_1) && File.file?(File.join(vd, _1)) }
      end
    end

    def delete_backups!(dir)
      raise Error, "#{dir} holds files that aren't flk backups; not deleting it" unless backup_files_only?(dir)
      FileUtils.rm_rf(dir)
    end

    def config_show(_args, _o)
      puts JSON.pretty_generate("file" => config.path, "parsed" => config.data, "machine_config" => config.machine_config,
                                "warnings" => warning_strings(config))
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
      { "id" => m.id, "name" => m.name, "state" => m.state, "desired_state" => m.desired_state,
        "pid" => m.running? ? m.pid : nil, "restart" => m.restart_policy, "restarts" => m.h["restarts"],
        "release" => m.release, "ip" => m.ip,
        "cpus" => m.config["cpus"], "memory_mb" => m.config["memory_mb"], "huge_pages" => m.config["huge_pages"],
        "internal_port" => m.config["internal_port"], "ports" => Array(m.config["ports"]),
        "volumes" => Array(m.config["mounts"]), "created_at" => m.created_at, "updated_at" => m.updated_at }
    end

    def machine_list(_args, o)
      reap_exited
      return puts(JSON.pretty_generate(app.machines.map { machine_json(_1) })) if o[:json]
      machine_table(app)
    end

    # ---------- host lifecycle ----------

    def lifecycle_machines = (@app_name ? [app] : App.all).flat_map(&:machines)

    def cmd_resume(_args, _o)
      todo = lifecycle_machines.select { _1.desired_state == "started" && !_1.running? }
      VM.ensure_server
      return puts("Nothing to resume") if todo.empty?
      puts "==> Resuming #{todo.size} machine#{'s' if todo.size > 1}"
      failed = todo.reject do |m|
        boot(m, "#{m.app.name}: #{m.id} [#{m.name}] resumed")
        true
      rescue Error => e
        warn Util.red("  ✘ #{m.app.name}: #{m.id} [#{m.name}]: #{e.message}")
        false
      end
      raise Error, "#{failed.size} machine#{'s' if failed.size > 1} didn't resume (see above; flk help troubleshoot)" if failed.any?
      next_step("flk context --all")
    end

    # Graceful, in parallel (each gets its kill_timeout), and remembering
    # they should run: what the host does at shutdown.
    def cmd_stop_all(_args, _o)
      todo = lifecycle_machines.select(&:running?)
      return puts("Nothing running") if todo.empty?
      puts "==> Stopping #{todo.size} machine#{'s' if todo.size > 1} (flk resume brings them back)"
      todo.map do |m|
        Thread.new do
          VM.stop(m, keep_desired: true, sync_ports: false)
          puts "  #{m.app.name}: #{m.id} [#{m.name}] stopped"
        rescue StandardError => e
          warn "  #{m.app.name}: #{m.id} [#{m.name}]: #{e.message}"
        end
      end.each(&:join)
      Ports.sync!
    end

    def machine_start(args, _o) = each_ref(args) { |m| boot(m, "Machine #{m.id} [#{m.name}] started") }
    def machine_stop(args, _o)
      each_ref(args) { |m| VM.stop(m); puts "Machine #{m.id} [#{m.name}] stopped (stays stopped, also after reboots)" }
      next_step("flk machine start #{args.join(' ')}")
    end
    def machine_restart(args, _o) = each_ref(args) { |m| VM.stop(m); boot(m, "Machine #{m.id} [#{m.name}] restarted") }
    def machine_destroy(args, o) = Util.with_lock { each_ref(args) { |m| destroy_machine(m, force: o[:force]) } }
    # Run by flk itself (VM.spawn_revive) when a machine exited on its own
    # and its restart policy wants it back: back off 1, 2, 4... up to 60s,
    # then boot, until `retries` restarts in a row. A run of 10+ minutes
    # resets the count.
    def machine_revive(args, _o)
      a = App.new(@app_name || raise(Error, "revive needs -a APP"))
      return unless a.exists?
      m = a.machines.find { _1.id == args[0] } or return
      policy = m.restart_policy
      started = (Time.parse(m.h["started_at"]) rescue Time.now)
      count = Time.now - started > 600 ? 0 : m.h.dig("restarts", "count").to_i
      status = m.last_exit_status
      note = ->(s) { File.open(m.path("console.log"), "a") { _1.puts "\n--- flk: #{s} (#{Util.now}) ---" } }
      if count >= policy["retries"]
        note["restart policy #{policy['policy']}: gave up after #{count} restarts in a row (last exit status #{status || 'none'})"]
        m.h["restarts"] = { "count" => count, "gave_up_at" => Util.now }
        Events.machine("machine.gave_up", m, "after #{count} restarts in a row (last exit status #{status || 'none'})")
        return m.save!
      end
      sleep [2**count, 60].min
      m = a.machines.find { _1.id == args[0] } or return # reload: someone may have acted meanwhile
      return if m.running? || m.desired_state != "started" || m.stopping?
      note["restart policy #{policy['policy']}: exit status #{status || 'none'}, restart #{count + 1} of #{policy['retries']}"]
      m.h["restarts"] = { "count" => count + 1, "last_at" => Util.now }
      boot(m, "Machine #{m.id} [#{m.name}] restarted by its restart policy", revive: true)
    end

    def machine_stats(args, o)
      reap_exited
      ms = if o[:all]
             raise Error, "--all takes no IDs (it's every machine)" if args.any?
             App.all.flat_map(&:machines)
           else
             args.empty? ? app.machines : args.map { app.machine!(_1) }
           end
      stats = VM.stats(ms)
      return puts(JSON.pretty_generate(stats)) if o[:json]
      return puts("No machines") if stats.empty?
      Util.table(%w[APP ID NAME STATE CPU RSS MEMORY UPTIME], stats.map do |s|
        [s["app"], s["id"], s["name"], s["state"], s["cpu_percent"] ? "#{s['cpu_percent']}%" : "-",
         s["rss_mb"] ? "#{s['rss_mb']}MB" : "-", "#{s['memory_mb']}MB", s["uptime_s"] ? duration(s["uptime_s"]) : "-"]
      end)
    end

    def duration(s)
      return "#{s}s" if s < 60
      return "#{s / 60}m" if s < 3600
      return "#{s / 3600}h#{(s % 3600) / 60}m" if s < 86_400
      "#{s / 86_400}d#{(s % 86_400) / 3600}h"
    end

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
        # Record the new scale only once it's known to fit: a refused scale
        # must not make the next deploy try it again.
        save_scale = -> { meta = a.meta; meta["scale"] = n; a.save_meta(meta) }
        rel = a.current_release
        unless rel
          save_scale.call
          next puts("Scale set to #{n}; applies on first deploy")
        end

        ms = a.machines
        if n > ms.size
          cfg = config_for(a.name)
          base = cfg ? cfg.machine_config : ms.last&.config&.reject { |k, _| k == "mounts" }
          raise Error, "run from the app directory so flk can read its config" unless base
          check_capacity!(a, base, creating: n - ms.size)
          save_scale.call
          (n - ms.size).times { create_machine(a, rel, base) }
        else
          save_scale.call
          ms.last(ms.size - n).reverse_each { destroy_machine(_1, force: true) }
        end
        puts "Scaled #{a.name} to #{n} machine#{'s' unless n == 1}"
        next_step("flk status")
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
      boot(m, "Machine #{m.id} [#{m.name}] created", event: "machine.created")
    end

    # The block runs while the machine is stopped (before_deploy backups).
    def update_machine(m, rel, mconfig)
      puts "  #{m.id} [#{m.name}] stopping" if m.running?
      VM.stop(m)
      yield if block_given?
      m.h["release"] = rel["version"]
      m.h["config"] = mconfig.merge("mounts" => attach_volumes(m.app, m.id, mconfig["mount_specs"]))
      m.save!
      install_rootfs(m, rel)
      boot(m, "Machine #{m.id} [#{m.name}] updated to v#{rel['version']}", event: "machine.updated")
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
      Events.machine("machine.destroyed", m)
      puts "Machine #{m.id} [#{m.name}] destroyed"
    end

    # revive: a restart by the restart policy; anything else is a person
    # starting it, which resets the count of restarts in a row.
    def boot(m, msg, revive: false, event: "machine.started")
      m.h.delete("restarts") unless revive
      VM.start(m)
      Events.machine(revive ? "machine.restarted" : event, m, msg)
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
      Array(m.config["ports"]).product(Ports.binds(m)).each do |p, bind|
        key = "#{p['proto']}/#{p['port']}"
        label = bind ? "#{bind}:#{key}" : key
        o = Ports.owner(key, bind)
        if (why = Ports.blocked_reason(p["proto"], p["port"], bind: bind))
          puts Util.yellow("    ⚠ host port #{label} not forwarded: #{why}")
        elsif o.nil? || !Ports.available?
          next
        elsif o["machine"] == m.id
          puts "    host port #{label} -> #{m.ip}:#{p['internal_port']}  " \
               "(reach it at #{bind || Net.host_address || 'the host LAN IP'}:#{p['port']}, not 127.0.0.1)"
        else
          puts Util.yellow("    ⚠ host port #{label} is taken by #{o['app']} (#{o['machine']}); this machine gets it when that one stops")
        end
      end
    end

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

    def ports_reap(_args, _o) = reap_exited(wait: true) # the tmux exit hook: no hurry, must not skip

    def ports_sync(_args, _o)
      reap_exited(wait: true)
      Ports.sync! or raise Error, "port forwarding not applied"
      puts "Port forwarding synced"
    end

    # active rows get "address": where to connect (host LAN IP:port)
    def ports_json
      active, waiting, blocked = Ports.table
      lan = Net.host_address
      { "helper_installed" => Ports.available?, "min_port" => Ports.min_port, "host_address" => lan,
        "per_address" => Ports.per_address?,
        "active" => active.map { _1.merge("address" => (a = _1["bind"] || lan) && "#{a}:#{_1['port']}") },
        "waiting" => waiting, "blocked" => blocked }
    end

    def ports_list(_args, o)
      reap_exited
      return puts(JSON.pretty_generate(ports_json)) if o[:json]
      active, waiting, blocked = Ports.table
      puts Util.yellow("Port helper not installed; run: sudo #{SETUP_HOST}\n") unless Ports.available?
      return puts("No forwarded ports (add [[services.ports]] to flk.toml)") if [active, waiting, blocked].all?(&:empty?)
      row = ->(r, status) { [Ports.label(r), r["machine"], "#{r['ip']}:#{r['internal_port']}", r["app"], status] }
      Util.table(%w[HOST_PORT MACHINE TARGET APP STATUS],
                 active.map { row[_1, "active"] } + waiting.map { row[_1, "waiting (port taken)"] } +
                 blocked.map { row[_1, "blocked: #{_1['blocked']}"] })
      return if active.empty?
      where = active.any? { _1["bind"].nil? } ? "#{Net.host_address || 'the host LAN IP'}:PORT" : "the address shown:PORT"
      puts "\nConnect to #{where} (from the host too) or the TARGET directly; " \
           "not 127.0.0.1, which isn't forwarded (for TCP: flk proxy PORT)."
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
      if o[:stage]
        puts "Staged; applies on next start/deploy"
        return next_step("flk deploy", "flk machine restart ID")
      end
      a.machines.select(&:running?).each do |m|
        VM.stop(m)
        boot(m, "Machine #{m.id} [#{m.name}] restarted with new secrets")
      end
    end

    # ---------- host: disk, images ----------

    # Allocated (sparse-aware) and apparent bytes of the files given.
    def du(paths)
      paths.each_with_object({ "bytes" => 0, "apparent" => 0 }) do |p, h|
        s = File.stat(p)
        next unless s.file?
        h["bytes"] += s.blocks * 512
        h["apparent"] += s.size
      rescue SystemCallError
        nil
      end
    end

    def du_tree(dir) = du(Dir.glob(File.join(dir, "**", "*"), File::FNM_DOTMATCH))

    def add_du(a, b) = { "bytes" => a["bytes"] + b["bytes"], "apparent" => a["apparent"] + b["apparent"] }

    DISK_KINDS = %w[images rootfs volumes logs external_volumes].freeze

    def cmd_disk(_args, o)
      zero = { "bytes" => 0, "apparent" => 0 }
      apps = App.all.map do |a|
        md = File.join(a.dir, "machines", "*")
        vols = a.volumes.map { _1["path"] }
        internal, external = vols.partition { _1.start_with?("#{ROOT}/") }
        h = { "app" => a.name,
              "images" => du(Dir[File.join(a.dir, "images", "*.ext4")]),
              "rootfs" => du(Dir[File.join(md, "{rootfs,config}.ext4")]),
              "volumes" => du(internal),
              "logs" => du(Dir[File.join(md, "{console.log,console.log.1,firecracker.log}")]),
              "external_volumes" => du(external) }
        h["total"] = DISK_KINDS[0..3].map { h[_1] }.reduce(zero) { add_du(_1, _2) } # in the state dir
        h
      end
      totals = DISK_KINDS.to_h { |k| [k, apps.map { _1[k] }.reduce(zero) { add_du(_1, _2) }] }
      backups = begin
        dir = Host.settings["backup_dir"]
        if dir && File.directory?(dir)
          per = App.all.to_h do |a|
            vols = a.volumes.map { _1["name"] }.uniq.to_h do |n|
              files = Dir[File.join(dir, a.name, n, "*.ext4")].grep(%r{/#{n}-\d{8}T\d{6}Z\.ext4\z})
              [n, du(Dir[File.join(dir, a.name, n, "*")]).merge("count" => files.size)]
            end
            [a.name, du_tree(File.join(dir, a.name)).merge("volumes" => vols)]
          end
          { "dir" => dir, "apps" => per }.merge(per.values.reduce(zero) { add_du(_1, _2) })
        end
      rescue Error
        nil
      end
      doc = { "state_dir" => { "path" => ROOT }.merge(du_tree(ROOT)), "apps" => apps,
              "totals" => totals, "backups" => backups }
      return puts(JSON.pretty_generate(doc)) if o[:json]
      gb = ->(h) { Backup.gb(h["bytes"]) }
      Util.table(%w[APP IMAGES ROOTFS VOLUMES LOGS TOTAL EXTERNAL_VOLUMES],
                 apps.map { |a| [a["app"], *%w[images rootfs volumes logs total external_volumes].map { gb[a[_1]] }] })
      puts "\nState dir #{ROOT}: #{gb[doc['state_dir']]}"
      puts "Backups in #{backups['dir']}: #{gb[backups]}" if backups
      puts "Container images: flk images"
    end

    def cmd_images(_args, o)
      rows = Image.list.map do |i|
        name = i["repo"].delete_prefix("flk.local/")
        a = App::NAME_RE.match?(name) ? App.new(name) : nil
        live = a&.exists?
        rel = i["tag"][/\Av(\d+)\z/, 1]&.to_i
        ms = live ? a.machines : []
        i.merge("app" => name, "release" => rel, "orphan" => !live,
                "current" => live && rel && a.current_release&.dig("version") == rel || false,
                "in_use" => !rel.nil? && ms.any? { _1.release == rel },
                "running" => !rel.nil? && ms.any? { _1.release == rel && _1.running? })
      end
      return puts(JSON.pretty_generate(rows)) if o[:json]
      return puts("No flk images") if rows.empty?
      Util.table(%w[REPO TAG SIZE CREATED STATUS], rows.map do |r|
        status = if r["orphan"] then "orphan (flk apps prune)"
                 elsif r["running"] then "running"
                 elsif r["in_use"] then "in use (stopped)"
                 elsif r["current"] then "current"
                 else "kept (rollback)"
                 end
        [r["repo"], r["tag"], r["size_bytes"] ? Backup.gb(r["size_bytes"]) : "?", r["created_at"] ? Util.ago(r["created_at"]) : "?", status]
      end)
    end

    def volumes_list(_args, o)
      v = app.volumes
      return puts(JSON.pretty_generate(v)) if o[:json]
      return puts("No volumes") if v.empty?
      ext = v.any? { App.external_volume?(_1) }
      Util.table(%w[ID NAME SIZE ATTACHED CREATED] + (ext ? ["FILE (external)"] : []),
                 v.map { [_1["id"], _1["name"], "#{_1['size_gb']}GB", _1["attached_machine"] || "-", Util.ago(_1["created_at"])] +
                         (ext ? [App.external_volume?(_1) ? _1["path"] : "-"] : []) })
    end

    def volume_name!(name)
      raise Error, "volume names: lowercase letters, digits, underscores" unless name.match?(/\A[a-z0-9_]{1,30}\z/)
      name
    end

    # An image file outside flk's state dir: flk never deletes it. Refuses a
    # file another volume (in any app) already uses.
    def external_path!(path)
      full = File.expand_path(path)
      raise Error, "#{full} is inside flk's state dir; leave out --path for that" if full.start_with?("#{ROOT}/")
      App.all.each do |other|
        if (v = other.volumes.find { _1["path"] == full })
          raise Error, "#{full} is already volume #{v['id']} (#{v['name']}) of app #{other.name}"
        end
      end
      full
    end

    def register_volume(a, h)
      Util.with_lock do
        vols = a.volumes
        vols << h.merge("attached_machine" => nil, "created_at" => Util.now)
        a.save_volumes(vols)
      end
    end

    def volumes_create(args, o)
      a = app
      name = volume_name!(args.first)
      size = o[:size] || 1
      raise Error, "--size must be at least 1 (GB)" if size < 1
      id = "vol_#{SecureRandom.hex(8)}"
      path = o[:path] ? external_path!(o[:path]) : File.join(a.dir, "volumes", "#{id}.ext4")
      if o[:path]
        raise Error, "#{path} already exists; to use an existing image: flk volumes import #{name} --path #{path}" if File.exist?(path)
        raise Error, "#{File.dirname(path)} doesn't exist" unless File.directory?(File.dirname(path))
      end
      from = o[:from_dir] && from_dir!(o[:from_dir], size)
      FileUtils.mkdir_p(File.dirname(path))
      puts "==> Copying #{from} into the volume (this can take a while)" if from
      Util.mkfs_ext4(path, size * 1024, label: name, from_dir: from)
      register_volume(a, { "id" => id, "name" => name, "size_gb" => size, "path" => path }.merge(o[:path] ? { "external" => true } : {}))
      puts "Created #{id} (#{name}, #{size}GB sparse#{", at #{path}" if o[:path]}#{", from #{from}" if from})"
      puts "Note: files keep their owner/group IDs from #{from}; the app may need to run as that user (or chown inside)." if from
      boot_unit_note(path) if o[:path]
      next_step("[[mounts]] source = \"#{name}\" in flk.toml, then flk deploy")
    end

    # A volume on another disk: the boot service must wait for that mount
    # (usually it already does; see mount_gap).
    def boot_unit_note(path)
      return unless File.exist?("/etc/systemd/system/flk-machines.service")
      problem, how = mount_gap(File.dirname(path))
      puts Util.yellow("#{problem}\n  -> #{how}") if problem
    end

    # --from-dir must fit with headroom: ext4 metadata takes a few percent.
    def from_dir!(dir, size_gb)
      full = File.expand_path(dir)
      raise Error, "#{full} isn't a directory" unless File.directory?(full)
      used = Util.run!("du", "-sb", full).split.first.to_i
      cap = size_gb * 1024**3
      if used > cap * 0.9
        raise Error, "#{full} holds #{(used / 1024.0**3).round(1)}GB, too much for a #{size_gb}GB volume; " \
                     "use --size #{(used * 1.25 / 1024**3).ceil}"
      end
      full
    end

    def volumes_import(args, o)
      a = app
      name = volume_name!(args.first)
      path = external_path!(o[:path] || raise(Error, "--path FILE is required"))
      raise Error, "#{path} doesn't exist" unless File.file?(path)
      raise Error, "#{path} isn't writable by you (machines open it read-write)" unless File.writable?(path)
      type = (Util.run!("blkid", "-o", "value", "-s", "TYPE", path).strip rescue "")
      raise Error, "#{path} isn't an ext4 image (blkid says '#{type.empty? ? 'unknown' : type}')" unless type == "ext4"
      id = "vol_#{SecureRandom.hex(8)}"
      size = (File.size(path) / 1024.0**3).ceil
      register_volume(a, { "id" => id, "name" => name, "size_gb" => size, "path" => path, "external" => true })
      puts "Imported #{path} as #{id} (#{name}, #{size}GB). flk won't delete this file."
      puts "Don't mount it on the host while a machine uses it."
      boot_unit_note(path)
      next_step("[[mounts]] source = \"#{name}\" in flk.toml, then flk deploy")
    end

    def backup_volumes(a, args) = args.empty? ? a.volumes : args.map { a.volume!(_1) }

    # The running machine using a volume, or nil.
    def volume_user(a, v)
      id = v["attached_machine"] or return nil
      a.machines.find { _1.id == id && _1.running? }
    end

    DEFAULT_BACKUP = { "mode" => "stop", "settle" => 5, "keep" => nil, "pre" => [], "post" => [] }.freeze

    # Copies each volume's image to the backup dir, keeping the app from
    # writing meanwhile as [flk.backup] says (AppConfig#backup).
    def volumes_backup(args, o)
      a = app
      vols = backup_volumes(a, args)
      raise Error, "#{a.name} has no volumes" if vols.empty?
      root = Backup.root!(o[:to])
      cfg = config_for(a.name)
      plan = cfg ? cfg.backup : DEFAULT_BACKUP
      if o[:mode]
        raise Error, "--mode must be stop, live or pause" unless AppConfig::BACKUP_MODES.include?(o[:mode])
        plan = plan.merge("mode" => o[:mode])
      end
      keep = Backup.keep(o[:keep] || plan["keep"])
      raise Error, "--keep must be at least 1" if keep < 1
      failed = vols.reject do |v|
        backup_one(a, v, root, plan, keep, cfg&.dir || Dir.pwd, check: !o[:no_check])
        if (dest = Host.settings["backup_copy_to"]) && !o[:no_copy]
          copy_one(a, v, root, Backup.copy_dest!(dest), nil, Backup.copy_keep(nil))
        end
        true
      rescue Error => e
        warn Util.red("  ✘ #{v['name']}: #{e.message}")
        Events.emit(e.message.start_with?("copy to ") ? "backup.copy_failed" : "backup.failed",
                    app: a.name, machine: v["attached_machine"], detail: "#{v['name']}: #{e.message}")
        false
      end
      raise Error, "#{failed.size} of #{vols.size} volume backups failed (see above)" if failed.any?
      next_step("flk volumes backups#{" --to #{o[:to]}" if o[:to]}")
    end

    # Returns the backup's path. fast: the machine is stopped for us (a
    # deploy), so copy at normal I/O priority.
    def backup_one(a, v, root, plan, keep, hook_dir, check:, fast: false, extra: {})
      src = v["path"]
      raise Error, "#{src} is missing (is its disk mounted?)" unless File.exist?(src)
      dir = Backup.dir_for(root, a.name, v)
      FileUtils.mkdir_p(dir)
      space = Backup.make_room!(src, root, a.name, v, keep)
      if space[:pruned].any?
        puts Util.yellow("  low on space in #{root}: pruned #{space[:pruned].size} old backup#{'s' if space[:pruned].size > 1} first " \
                         "(#{space[:pruned].join(', ')})")
      end
      if space[:steady] > space[:available]
        puts Util.yellow("  ⚠ #{keep} backups of #{v['name']} will take about #{Backup.gb(space[:steady])}; " \
                         "#{root} has room for about #{Backup.gb(space[:available])} (lower keep, or free space)")
      end
      m = volume_user(a, v)
      mode = m ? plan["mode"] : "offline"
      dst = File.join(dir, "#{v['name']}-#{Time.now.utc.strftime(Backup::STAMP)}.ext4")
      raise Error, "#{File.basename(dst)} already exists (two backups in one second); try again" if File.exist?(dst)
      puts "==> #{a.name}/#{v['name']}: #{Backup.gb(Backup.used_bytes(src))} used, " \
           "#{m ? "machine #{m.id} running, mode #{mode}" : 'no machine running'} -> #{dst}"
      t0 = Time.now
      window = backup_copy(m, src, dst, mode, plan, hook_dir, fast: fast)
      took = Time.now - t0
      state, replayed = check ? Backup.check(dst) : ["unchecked", false]
      Backup.write_meta(dst, { "app" => a.name, "volume_id" => v["id"], "volume" => v["name"], "size_gb" => v["size_gb"],
                               "source" => src, "machine" => m&.id, "release" => m&.release, "mode" => mode,
                               "check" => state, "journal_replayed" => replayed,
                               "created_at" => Util.now, "seconds" => took.round(1) }.merge(extra))
      what = { "stop" => "machine down", "pause" => "machine paused", "live" => "copied live" }[mode]
      puts "  #{Util.green('✔')} #{File.basename(dst)} in #{took.round(1)}s" \
           "#{" (#{what} #{window.round(1)}s)" if what}, fsck: #{state}#{' (journal replayed)' if replayed}"
      if plan["verify"] && check && state != "errors"
        res = Backup.verify(Backup.list(root, a.name, v).find { _1["path"] == dst }, hook: plan["verify"], hook_dir: hook_dir,
                            env: { "FLK_APP" => a.name, "FLK_VOLUME" => v["name"] })
        puts "  #{res['verify'] == 'clean' ? Util.green('✔') : Util.red('✘')} verify hook: #{res['verify']}"
        raise Error, "the verify hook failed for #{File.basename(dst)}: #{res['verify_detail']}" unless res["verify"] == "clean"
      end
      log = dst.sub(/\.ext4\z/, ".fsck.log")
      if state == "errors"
        puts Util.yellow("  ⚠ e2fsck found errors it couldn't fix in the copy (#{log}); keep older backups until you've checked it")
      elsif state == "repaired"
        puts Util.yellow("  ⚠ e2fsck had to repair the copy (#{log}): the app was writing, or the volume has damage")
      end
      if Backup.same_fs?(src, dir)
        puts "  note: same disk as the volume (covers mistakes and corruption, not a failed disk)"
      end
      pruned = Backup.prune(root, a.name, v, keep)
      puts "  pruned #{pruned.size} old backup#{'s' if pruned.size > 1} (keeping #{keep})" if pruned.any?
      Events.emit("backup.succeeded", app: a.name, machine: m&.id, release: m&.release,
                                      detail: "#{v['name']}: #{File.basename(dst)}, mode #{mode}, fsck #{state}, #{took.round(1)}s")
      dst
    end

    # The copy itself; returns how long the machine was down, paused or
    # (live) being copied. Post hooks run even when something failed, so a
    # save-off is always undone.
    def backup_copy(m, src, dst, mode, plan, hook_dir, fast: false)
      unless m
        Backup.copy(src, dst, idle: !fast)
        return 0
      end
      begin
        backup_hooks(m, plan["pre"], "pre", hook_dir)
        sleep plan["settle"] if mode != "stop" && plan["settle"].positive?
        t = Time.now
        case mode
        when "stop"
          File.write(m.path("backup"), Process.pid.to_s)
          begin
            VM.stop(m, keep_desired: true, sync_ports: false)
            Backup.copy(src, dst, idle: false) # the machine is down: be quick
          ensure
            FileUtils.rm_f(m.path("backup"))
            window = Time.now - t
            boot(m, "Machine #{m.id} [#{m.name}] started again after the backup")
          end
        when "pause"
          VM.pause(m)
          Events.machine("machine.paused", m, "pause-mode backup")
          begin
            Backup.copy(src, dst, idle: false) # the machine is frozen: be quick
          ensure
            VM.resume(m)
            Events.machine("machine.resumed", m, "after the backup")
            window = Time.now - t
          end
        else
          Backup.copy(src, dst)
          window = Time.now - t
        end
      ensure
        begin
          backup_hooks(m, plan["post"], "post", hook_dir)
        rescue Error => e
          warn Util.red("  ✘ post hook: #{e.message}")
        end
      end
      window
    end

    # [flk.backup] pre/post hooks: host commands (in the flk.toml's dir, with
    # FLK_APP, FLK_MACHINE, FLK_MACHINE_IP set) or console lines.
    def backup_hooks(m, hooks, phase, dir)
      hooks.each do |h|
        if h["run"]
          puts "  #{phase}: #{h['run']}"
          env = { "FLK_APP" => m.app.name, "FLK_MACHINE" => m.id, "FLK_MACHINE_IP" => m.ip }
          pid = Process.spawn(env, "sh", "-c", h["run"], chdir: dir, in: File::NULL)
          unless Util.wait_for(120, 0.1) { Process.wait(pid, Process::WNOHANG) }
            VM.kill(pid, "KILL")
            Process.wait(pid)
            raise Error, "#{phase} hook timed out after 120s: #{h['run']}"
          end
          raise Error, "#{phase} hook failed (exit #{$?.exitstatus}): #{h['run']}" unless $?.success?
        else
          puts "  #{phase}: console: #{h['console']}"
          log = m.path("console.log")
          offset = File.size?(log) || 0
          VM.send_line(m, h["console"])
          wait_for_log(log, offset, Regexp.new(h["wait"]), h["console"], h["timeout"]) if h["wait"]
        end
      end
    end

    def volumes_copy(args, o)
      a = app
      root = Backup.root!(o[:to])
      dest = Backup.copy_dest!(o[:dest] || Host.settings["backup_copy_to"])
      keep = Backup.copy_keep(o[:keep])
      raise Error, "--keep must be at least 1" if keep < 1
      vols = backup_volumes(a, args)
      raise Error, "#{a.name} has no volumes" if vols.empty?
      failed = vols.reject do |v|
        copy_one(a, v, root, dest, o[:backup], keep)
        true
      rescue Error => e
        warn Util.red("  ✘ #{v['name']}: #{e.message}")
        Events.emit("backup.copy_failed", app: a.name, detail: "#{v['name']}: #{e.message}")
        false
      end
      raise Error, "#{failed.size} of #{vols.size} copies failed (see above)" if failed.any?
      next_step("flk volumes backups")
    end

    def copy_one(a, v, root, dest, ref, keep)
      b = Backup.find!(root, a.name, v, ref)
      print "==> copy #{v['name']}/#{b['file']} to #{dest} "
      e = Backup.send_copy(b, dest, a.name, v["name"], keep: keep)
      raise Error, "copy to #{dest} failed: #{e['error']}" unless e["ok"]
      Events.emit("backup.copied", app: a.name, detail: "#{v['name']}: #{b['file']} to #{dest}#{' (already there)' if e['already']}")
      puts "#{Util.green('✔')} #{e['already'] ? 'already there' : "#{e['seconds']}s"}" \
           "#{"; pruned #{e['pruned'].size} old cop#{e['pruned'].size == 1 ? 'y' : 'ies'} there (keeping #{keep})" if e['pruned'].any?}"
    rescue Error
      puts Util.red("✘") if b
      raise
    end

    def volumes_backups(args, o)
      a = app
      root = Backup.root!(o[:to])
      rows = backup_volumes(a, args).flat_map { |v| Backup.list(root, a.name, v).map { _1.merge("volume" => v["name"]) } }
      return puts(JSON.pretty_generate(rows)) if o[:json]
      return puts("No backups of #{a.name} in #{root}") if rows.empty?
      Util.table(%w[VOLUME BACKUP CREATED USED MODE CHECK VERIFIED COPIES],
                 rows.map { [_1["volume"], _1["file"], Util.ago(_1["created_at"]), Backup.gb(_1["bytes_used"]),
                             _1["mode"] || "-", _1["check"] || "-",
                             _1["verified_at"] ? "#{_1['verify']} #{Util.ago(_1['verified_at'])}" : "-",
                             Array(_1["copies"]).map { |c| "#{c['ok'] ? '' : 'FAILED '}#{c['to']}" }.join(", ").then { |s| s.empty? ? "-" : s }] })
    end

    def volumes_verify(args, o)
      a = app
      root = Backup.root!(o[:to])
      cfg = config_for(a.name)
      hook = cfg&.backup&.dig("verify")
      raise Error, "--backup and --all don't go together" if o[:backup] && o[:all]
      results = backup_volumes(a, args).flat_map do |v|
        bs = o[:all] ? Backup.list(root, a.name, v) : [Backup.find!(root, a.name, v, o[:backup])]
        bs.map do |b|
          print "==> #{v['name']}/#{b['file']} " unless o[:json]
          $stdout.flush
          r = Backup.verify(b, hook: hook, hook_dir: cfg&.dir || Dir.pwd, env: { "FLK_APP" => a.name, "FLK_VOLUME" => v["name"] })
          puts "#{r['verify'] == 'clean' ? Util.green('✔') : Util.red('✘')} #{r['verify']}: #{r['verify_detail']}" unless o[:json]
          r.merge("volume" => v["name"], "file" => b["file"], "path" => b["path"])
        end
      end
      raise Error, "#{a.name} has no volumes" if results.empty? && !o[:json]
      if o[:json]
        puts JSON.pretty_generate(results)
      else
        puts "  (no [flk.backup] verify hook: e2fsck only)" unless hook
      end
      bad = results.reject { _1["verify"] == "clean" }
      raise Error, "#{bad.size} of #{results.size} backups aren't clean" if bad.any?
      next_step("flk volumes backups") unless o[:json]
    end

    # The volume a backup belongs to; with allow_gone, also one that was
    # destroyed (its backups are kept by name).
    def backup_volume!(a, ref, allow_gone: false)
      a.volume!(ref)
    rescue Error
      raise unless allow_gone && ref.match?(/\A[a-z0-9_]{1,30}\z/)
      { "name" => ref }
    end

    # A backup into a new, unattached volume, with nothing stopped.
    def restore_as(a, v, b, o)
      name = volume_name!(o[:as])
      id = "vol_#{SecureRandom.hex(8)}"
      path = o[:path] ? external_path!(o[:path]) : File.join(a.dir, "volumes", "#{id}.ext4")
      raise Error, "#{path} already exists" if File.exist?(path)
      raise Error, "#{File.dirname(path)} doesn't exist" if o[:path] && !File.directory?(File.dirname(path))
      FileUtils.mkdir_p(File.dirname(path))
      Backup.room!(b["path"], File.dirname(path))
      puts "==> Restoring #{b['file']} (#{Util.ago(b['created_at'])}) as new volume #{name}"
      t0 = Time.now
      begin
        Backup.copy(b["path"], path)
        state, = Backup.check(path) if Backup.needs_recovery?(path) # an unchecked copy: replay its journal
      rescue StandardError
        FileUtils.rm_f(path)
        raise
      end
      raise Error, "e2fsck found errors it couldn't fix in #{path}" if state == "errors"
      register_volume(a, { "id" => id, "name" => name, "size_gb" => (File.size(path) / 1024.0**3).ceil, "path" => path,
                           "restored_from" => b["file"] }.merge(o[:path] ? { "external" => true } : {}))
      puts "Restored #{b['file']} into #{id} (#{name}) in #{(Time.now - t0).round(1)}s#{", at #{path}" if o[:path]}. " \
           "#{v['name']} wasn't touched."
      if (config_for(a.name)&.mounts || []).any? { _1["source"] == name }
        puts Util.yellow("Note: #{name} is a [[mounts]] source, so the next machine that needs a #{name} volume may attach this one.")
      end
      next_step("debugfs -R 'ls -l /' #{path}   (look inside)", "flk volumes destroy #{name}   (when done)")
    end

    def volumes_restore(args, o)
      raise Error, "restore takes a volume and optionally a backup" unless (1..2).cover?(args.size)
      raise Error, "--path goes with --as" if o[:path] && !o[:as]
      a = app
      v = backup_volume!(a, args[0], allow_gone: o[:as])
      b = Backup.find!(Backup.root!(o[:to]), a.name, v, args[1])
      return restore_as(a, v, b, o) if o[:as]
      if (m = volume_user(a, v))
        raise Error, "machine #{m.id} [#{m.name}] is using #{v['name']}; stop it first: flk machine stop #{m.id}"
      end
      dst = v["path"]
      Backup.room!(b["path"], File.dirname(dst))
      aside = "#{dst}.before-restore-#{Time.now.utc.strftime(Backup::STAMP)}"
      puts "==> Restoring #{v['name']} from #{b['file']} (#{Util.ago(b['created_at'])})"
      Util.with_lock do
        raise Error, "#{v['name']} is in use again" if volume_user(a, v)
        Backup.copy(b["path"], "#{dst}.restoring")
        File.rename(dst, aside) if File.exist?(dst)
        File.rename("#{dst}.restoring", dst)
        set_volume_size(a, v, dst)
        Events.emit("volume.restored", app: a.name, machine: v["attached_machine"], detail: "#{v['name']} from #{b['file']}")
      end
      puts "Restored #{v['name']}. The previous image is kept at #{aside}; delete it when you're happy."
      next_step(v["attached_machine"] ? "flk machine start #{v['attached_machine']}" : "flk deploy")
    end

    # ---------- files in volumes ----------

    VOL_REF = /\A([a-z0-9_]{1,30}|vol_\h{16}):(.*)\z/m

    # "VOL:PATH" (or "VOL" when bare is allowed) -> [volume, path], else nil.
    def vol_ref(arg, bare: false)
      md = VOL_REF.match(arg) || (bare && arg.match?(/\A([a-z0-9_]{1,30}|vol_\h{16})\z/) ? [nil, arg, "/"] : nil)
      return nil unless md
      v = app.volumes.find { _1["id"] == md[1] } || app.volumes.find { _1["name"] == md[1] }
      return nil unless v
      [v, VolFS.clean(md[2].empty? ? "/" : md[2])]
    end

    def vol_ref!(arg, bare: false)
      vol_ref(arg, bare: bare) || raise(Error, "'#{arg}' isn't VOL:PATH for a volume of #{app.name} (see: flk volumes list)")
    end

    # The image to read: the volume, or with --backup one of its backups.
    def read_image(v, o)
      return Backup.find!(Backup.root!(o[:to]), app.name, v, o[:backup])["path"] if o[:backup]
      raise Error, "#{v['path']} is missing (is its disk mounted?)" unless File.exist?(v["path"])
      if volume_user(app, v)
        warn Util.yellow("note: #{v['name']} is in use by a running machine; this is what's on disk now " \
                         "(recent writes may still be in the guest's cache; --backup reads a backup)")
      end
      v["path"]
    end

    # Runs the block (returning debugfs commands) with v's machine stopped
    # and flk's lock held, applies them and checks the volume.
    def write_volume(v)
      a = app
      Util.with_lock do
        if (m = volume_user(a, v))
          raise Error, "machine #{m.id} [#{m.name}] is using #{v['name']}; stop it first: flk machine stop #{m.id}"
        end
        raise Error, "#{v['path']} is missing (is its disk mounted?)" unless File.exist?(v["path"])
        VolFS.batch!(v["path"], yield(v["path"]))
        state = VolFS.fsck!(v["path"])
        puts Util.yellow("  e2fsck repaired #{v['name']} afterwards") if state == "repaired"
      end
    end

    def owner_opt(s)
      md = /\A(\d+)(?::(\d+))?\z/.match(s.to_s) or raise Error, "--owner/chown takes numeric UID or UID:GID (got '#{s}')"
      [md[1].to_i, md[2]&.to_i]
    end

    def files_ls(args, o)
      raise Error, "ls takes one VOL[:PATH]" unless args.size == 1
      v, path = vol_ref!(args[0], bare: true)
      rows = VolFS.list(read_image(v, o), path)
      return puts(JSON.pretty_generate(rows.map(&:to_h))) if o[:json]
      return puts("(empty)") if rows.empty?
      Util.table(%w[MODE UID GID SIZE MODIFIED NAME],
                 rows.map { [_1.mode, _1.uid, _1.gid, _1.size, _1.mtime ? Time.parse(_1.mtime).localtime.strftime("%Y-%m-%d %H:%M") : "-",
                             _1.dir? ? "#{_1.name}/" : _1.name] })
    end

    def files_cat(args, o)
      raise Error, "cat takes one VOL:PATH" unless args.size == 1
      v, path = vol_ref!(args[0])
      $stdout.binmode.write(VolFS.read(read_image(v, o), path))
    end

    def files_cp(args, o)
      raise Error, "cp takes SRC and DST" unless args.size == 2
      src, dst = args.map { vol_ref(_1) }
      raise Error, "one side must be VOL:PATH (a volume of #{app.name})" if !src && !dst
      raise Error, "copy between volumes through a local dir (one side local)" if src && dst
      if src
        v, path = src
        img = read_image(v, o)
        if args[1].end_with?("/") && !File.directory?(args[1])
          raise Error, "#{args[1]}: no such directory"
        end
        local = File.directory?(args[1]) ? File.join(args[1], path == "/" ? v["name"] : File.basename(path)) : args[1]
        raise Error, "#{File.dirname(File.expand_path(local))}: no such directory" unless File.directory?(File.dirname(File.expand_path(local)))
        VolFS.export(img, path, local)
        puts "Copied #{v['name']}:#{path} to #{local}"
      else
        raise Error, "--backup is for copying out of a backup" if o[:backup]
        local = File.expand_path(args[0])
        raise Error, "#{args[0]} doesn't exist" unless File.exist?(local) || File.symlink?(local)
        v, path = dst
        write_volume(v) do |img|
          e = VolFS.stat(img, path)
          target = e&.dir? ? File.join(path, File.basename(local)) : path
          parent = VolFS.stat!(img, File.dirname(target))
          raise Error, "#{File.dirname(target)} isn't a directory" unless parent.dir?
          uid, gid = o[:owner] ? owner_opt(o[:owner]) : [parent.uid, parent.gid]
          gid ||= uid
          cmds = []
          if (t = VolFS.stat(img, target))
            raise Error, "#{target} is a directory in the volume; rm -r it first to replace it" if t.dir?
            raise Error, "#{target} exists in the volume and #{args[0]} is a directory" if File.directory?(local)
            cmds << "rm #{VolFS.q(target)}"
          end
          puts "==> #{args[0]} -> #{v['name']}:#{target} (owner #{uid}:#{gid})"
          cmds + VolFS.import_cmds(local, target, uid, gid)
        end
        puts "Copied into #{v['name']}"
        next_step(v["attached_machine"] ? "flk machine start #{v['attached_machine']}" : "flk files ls #{v['name']}:#{File.dirname(path)}")
      end
    end

    def files_rm(args, o)
      raise Error, "rm takes one VOL:PATH" unless args.size == 1
      v, path = vol_ref!(args[0])
      raise Error, "won't delete / of a volume (destroy the volume instead)" if path == "/"
      write_volume(v) { |img| VolFS.remove_cmds(img, path, recursive: o[:recursive]) }
      puts "Deleted #{v['name']}:#{path}"
    end

    def files_mkdir(args, o)
      raise Error, "mkdir takes one VOL:PATH" unless args.size == 1
      v, path = vol_ref!(args[0])
      write_volume(v) do |img|
        if (e = VolFS.stat(img, path))
          raise Error, "#{path} exists" unless o[:parents] && e.dir?
          next []
        end
        missing = []
        p = path
        until (parent = VolFS.stat(img, p))
          missing.unshift(p)
          p = File.dirname(p)
        end
        raise Error, "#{p} isn't a directory" unless parent.dir?
        raise Error, "#{File.dirname(path)} doesn't exist (use -p)" if missing.size > 1 && !o[:parents]
        uid, gid = o[:owner] ? owner_opt(o[:owner]) : [parent.uid, parent.gid]
        gid ||= uid
        missing.flat_map { ["mkdir #{VolFS.q(_1)}", *VolFS.owner_cmds(_1, uid, gid)] }
      end
      puts "Made #{v['name']}:#{path}"
    end

    def files_chown(args, o)
      raise Error, "chown takes UID[:GID] and VOL:PATH" unless args.size == 2
      uid, gid = owner_opt(args[0])
      v, path = vol_ref!(args[1])
      write_volume(v) { |img| VolFS.chown_cmds(img, path, uid, gid, recursive: o[:recursive]) }
      puts "Changed the owner of #{v['name']}:#{path}#{' and everything under it' if o[:recursive]} to #{uid}#{":#{gid}" if gid}"
    end

    def volumes_move(args, o)
      a = app
      v = a.volume!(args.first)
      raise Error, "pass --dir DIR or --path FILE" unless o[:dir] || o[:path]
      raise Error, "--dir and --path don't go together" if o[:dir] && o[:path]
      if (m = volume_user(a, v))
        raise Error, "machine #{m.id} [#{m.name}] is using #{v['name']}; stop it first: flk machine stop #{m.id}"
      end
      src = v["path"]
      raise Error, "#{src} is missing (is its disk mounted?)" unless File.exist?(src)
      dst = File.expand_path(o[:path] || File.join(o[:dir], App.external_volume?(v) ? File.basename(src) : "#{a.name}-#{v['name']}-#{v['id']}.ext4"))
      raise Error, "#{v['name']} is already at #{dst}" if dst == src
      raise Error, "#{dst} already exists" if File.exist?(dst)
      raise Error, "#{File.dirname(dst)} doesn't exist" unless File.directory?(File.dirname(dst))
      internal = dst.start_with?("#{ROOT}/")
      external_path!(dst) unless internal # another volume's file?
      Backup.room!(src, File.dirname(dst))
      puts "==> Moving #{v['name']} (#{Backup.gb(Backup.used_bytes(src))} used) to #{dst}"
      t0 = Time.now
      Util.with_lock do
        raise Error, "#{v['name']} is in use again" if volume_user(a, v)
        begin
          Backup.copy(src, dst, idle: false)
          raise Error, "the copy at #{dst} isn't clean (e2fsck -n); the volume still uses #{src}" unless Backup.fsck_readonly(dst) == "clean"
        rescue StandardError
          FileUtils.rm_f(dst)
          raise
        end
        vols = a.volumes
        rec = vols.find { _1["id"] == v["id"] }
        rec["path"] = dst
        internal ? rec.delete("external") : rec["external"] = true
        a.save_volumes(vols)
      end
      old_kept = App.external_volume?(v)
      FileUtils.rm_f(src) unless old_kept
      puts "Moved #{v['name']} in #{(Time.now - t0).round(1)}s#{" (#{fs_type(dst)}#{', backups there are instant' if %w[xfs btrfs].include?(fs_type(dst))})" if fs_type(dst)}."
      puts old_kept ? "The old file is kept (flk doesn't delete external files): #{src}" : "Deleted the old file #{src}."
      boot_unit_note(dst) unless internal
      next_step(v["attached_machine"] ? "flk machine start #{v['attached_machine']}" : "flk deploy")
    end

    def fs_type(path)
      dir = File.directory?(path) ? path : File.dirname(path)
      out, st = Open3.capture2("findmnt", "-n", "-o", "FSTYPE", "--target", dir)
      out, st = Open3.capture2("stat", "-f", "-c", "%T", dir) unless st.success? && !out.strip.empty?
      st.success? ? out.strip : nil
    rescue SystemCallError
      nil
    end

    def volumes_extend(args, o)
      a = app
      v = a.volume!(args.first)
      size = o[:size] or raise Error, "--size GB is required"
      raise Error, "#{v['name']} is #{v['size_gb']}GB; volumes only grow (--size more than that)" unless size > v["size_gb"].to_i
      if (m = volume_user(a, v))
        raise Error, "machine #{m.id} [#{m.name}] is using #{v['name']}; stop it first: flk machine stop #{m.id}"
      end
      path = v["path"]
      Util.with_lock do
        fsck = Util.which("e2fsck") || "/usr/sbin/e2fsck"
        out, st = Open3.capture2e(fsck, "-fy", path)
        raise Error, "e2fsck found errors it couldn't fix in #{path}:\n#{out}" if st.exitstatus.to_i > 2
        File.open(path, "r+") { _1.truncate(size * 1024**3) } # sparse: takes no space until used
        Util.run!(Util.which("resize2fs") || "/usr/sbin/resize2fs", path)
        set_volume_size(a, v, path)
      end
      puts "Extended #{v['name']} to #{size}GB"
      next_step(v["attached_machine"] ? "flk machine start #{v['attached_machine']}" : "flk deploy")
    end

    def set_volume_size(a, v, path)
      vols = a.volumes
      vols.find { _1["id"] == v["id"] }["size_gb"] = (File.size(path) / 1024.0**3).ceil
      a.save_volumes(vols)
    end

    # External volumes (--path / import) are only unregistered unless
    # --delete-data: flk didn't create that file, so it won't silently delete it.
    def volumes_destroy(args, o)
      a = app
      ref = args.first
      Util.with_lock do
        v = a.volume!(ref)
        if v["attached_machine"]
          raise Error, "#{v['id']} is attached to machine #{v['attached_machine']}; destroy that machine first"
        end
        keep = App.external_volume?(v) && !o[:delete_data]
        FileUtils.rm_f(v["path"]) unless keep
        a.save_volumes(a.volumes.reject { _1["id"] == v["id"] })
        puts keep ? "Unregistered #{v['id']}; file kept at #{v['path']} (--delete-data deletes it)" : "Destroyed #{v['id']}"
      end
    end
  end
end
