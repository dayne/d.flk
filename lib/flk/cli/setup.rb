module Flk
  # flk version, help, completion, setup, doctor (and its checks)
  class CLI
    private

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

    SETUP_BIN = File.expand_path("../../../bin/flk", __dir__).freeze

    # "Next: ..." after commands that change things, so nobody has to
    # remember the order. One line, plain, after the result.
    def cmd_setup(_args, o)
      setup_preflight_packages!
      Util.sh!(File.join(LIBEXEC, "flk-fetch-assets"))
      puts "==> flk-agent (flk exec): #{Agent.ensure! || 'not built'}"
      setup_post_fixes(o) # before doctor, so its report shows them done
      puts
      cmd_doctor([], {})
    end

    # Fail before the download, not halfway through (curl) or at the first
    # deploy (the rest).
    def setup_preflight_packages!
      missing = { "curl" => "curl", "tmux" => "tmux", "mkfs.ext4" => "e2fsprogs", "fakeroot" => "fakeroot" }
                 .reject { |bin, _| Util.which(bin) }
                 .values
      eng = begin; Image.engine; rescue Error; nil; end
      missing << "podman (or docker)" unless eng
      return if missing.empty?

      sanity = File.join(File.dirname(SHARE), "flk-sanity.sh")
      raise Error,
            "missing packages: #{missing.join(', ')}. " \
            "Run #{sanity} --only packages for the exact install command, then re-run flk setup"
    end

    def setup_post_fixes(o)
      fixes = {}
      fixes[:registries] = "podman short image names (FROM ruby:3.3 and friends)" if setup_needs_registries?
      fixes[:symlink]    = "flk PATH symlink (~/.local/bin/flk -> #{SETUP_BIN})"  if setup_needs_symlink?
      return if fixes.empty?

      if o[:fix]
        fixes.each_key { |k| setup_apply_fix!(k) }
      elsif $stdin.tty? && $stdout.tty?
        puts "\n#{fixes.size} auto-fixable item#{'s' if fixes.size > 1} (no root needed):"
        fixes.each_value { |v| puts "  - #{v}" }
        print "Apply now? [Y/n] "
        input = $stdin.gets.to_s.strip.downcase
        fixes.each_key { |k| setup_apply_fix!(k) } if input.empty? || input == "y"
      else
        puts "\nTip: re-run with `flk setup --fix` to apply the above automatically"
      end
    end

    def setup_needs_registries?
      eng = begin; Image.engine; rescue Error; nil; end
      eng && Image.podman?(eng) && !Image.short_names_resolve?
    end

    def setup_needs_symlink?
      target = File.expand_path("~/.local/bin/flk")
      return false if File.exist?(target) || File.symlink?(target)
      Util.which("flk").nil?
    end

    def setup_apply_fix!(key)
      case key
      when :registries
        path = File.expand_path(Image::REGISTRIES_DROPIN)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "unqualified-search-registries = [\"docker.io\"]\n")
        puts "==> Configured podman short image names (#{path})"
      when :symlink
        dir = File.expand_path("~/.local/bin")
        FileUtils.mkdir_p(dir)
        target = File.join(dir, "flk")
        File.symlink(SETUP_BIN, target)
        puts "==> Linked #{target} -> #{SETUP_BIN}"
        unless ENV["PATH"].split(File::PATH_SEPARATOR).include?(dir)
          puts "    #{dir} isn't on PATH in this shell: log in again (Ubuntu's ~/.profile adds it once it exists),"
          puts "    or add to your shell rc: export PATH=\"$HOME/.local/bin:$PATH\""
        end
      end
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
      warns, main = results.partition { _1["status"] == "warn" }
      main.each { |c| puts "#{icons[c['status']]} #{c['label']}#{c['hint'] ? "  -> #{c['hint']}" : ''}" }
      puts(ok ? "\nReady to fly, locally." : "\nFix the ✘ items above.")
      if warns.any?
        puts "\nOptional (flk works without these):"
        warns.each { |c| puts "#{icons['warn']} #{c['label']}#{c['hint'] ? "  -> #{c['hint']}" : ''}" }
      end
    end

    def doctor_checks
      results = []
      record = lambda do |label, status, hint|
        results << { "label" => label, "status" => status, "hint" => status == "pass" ? nil : hint }
      end
      check = ->(label, ok, hint = nil) { record[label, ok ? "pass" : "fail", hint] }
      check["/dev/kvm read/write", File.readable?("/dev/kvm") && File.writable?("/dev/kvm"),
            "#{Util.setup_host_cmd} (adds you to kvm group; log out/in)"]
      check["bridge #{Net::BRIDGE}", Net.bridge_up?, Util.setup_host_cmd]
      taps = (0...Net::POOL).count { Net.tap_exists?(_1) }
      check["tap pool #{taps}/#{Net::POOL}", taps.positive?, Util.setup_host_cmd]
      fwd = (File.read("/proc/sys/net/ipv4/ip_forward").strip == "1" rescue false)
      check["ipv4 forwarding", fwd, Util.setup_host_cmd]
      fc = begin; VM.firecracker_bin; rescue Error; nil; end
      check["firecracker #{fc}", !fc.nil?, "flk setup"]
      check["guest kernel #{VM.kernel}", File.exist?(VM.kernel), "flk setup"]
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
      tmux_server_check(record)
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

    # flk's tmux server and its machines must live in flk-tmux.service (or
    # flk-machines.service, which started it before flk-tmux existed). A
    # server a login shell started lives in that session's scope (and tmux
    # may give each pane a tmux-spawn scope of the user's), which shutdown
    # kills alongside the boot service: the machines die before stop-all
    # can stop them.
    def tmux_server_check(record)
      return unless VM::SOCKET == "flk" && File.exist?("/etc/systemd/system/flk-machines.service")
      server = VM.tmux_server_pid or return
      pids = [server] + App.all.flat_map(&:machines).select(&:running?).map(&:pid)
      units = pids.filter_map { VM.cgroup_unit(_1) }.uniq
      return if units.empty?
      stray = units - [VM::SERVER_UNIT, "flk-machines.service"]
      if stray.empty?
        record["machines run under #{units.join(', ')} (stopped gracefully at shutdown)", "pass", nil]
      else
        restart = VM.server_unit? ? "flk resume" : "sudo systemctl restart flk-machines.service"
        record["flk's tmux server or machines run in #{stray.first(3).join(', ')}, not a flk service: " \
               "at shutdown they're killed, not stopped", "warn",
               "when they can stop: flk stop-all && #{VM::TMUX.join(' ')} kill-server && #{restart}"]
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
               Util.setup_host_cmd]
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

    FLK_UNITS = %w[flk-net.service flk-machines.service flk-tmux.service].freeze

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
               "flk config set backup_dir=/path/to/backups"]
      elsif !File.directory?(dir) || !File.writable?(dir)
        record["backup_dir #{dir} is missing or not writable (disk not mounted?)", "warn",
               "mount it, or: flk config set backup_dir=/new/path"]
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
      elsif !File.exist?("/etc/systemd/system/#{VM::SERVER_UNIT}")
        record["boot service predates #{VM::SERVER_UNIT}: machines started from a shell can be killed, " \
               "not stopped, at shutdown", "warn", fix]
      elsif (gaps = mount_dirs.filter_map { mount_gap(_1) }).any?
        gaps.each { |problem, how| record[problem, "warn", how] }
      else
        record["boot service (machines come back after a reboot)", "pass", nil]
      end
    rescue SystemCallError
      record["boot service: systemctl not found", "warn", "after a reboot: #{Util.setup_host_cmd} && flk resume"]
    end

    # Optional: without it machines run, but [[services.ports]] isn't forwarded.
    def port_helper_check(record)
      fix = Util.setup_host_cmd
      if !Ports.available?
        record["port helper (forwarding [[services.ports]])", "warn", fix]
      elsif !system("sudo", "-n", "-l", Ports::HELPER, out: File::NULL, err: File::NULL)
        record["port helper usable without a password", "warn", fix]
      elsif !File.read(Ports::HELPER).match?(/^min_port=/)
        record["port helper up to date (host port guard)", "warn", fix]
      elsif VM.server_unit? && !File.read(Ports::HELPER).include?("start-tmux")
        record["port helper predates #{VM::SERVER_UNIT}: flk can't start its tmux server there", "warn", fix]
      else
        record["port helper (host ports from #{Ports.min_port})", "pass", nil]
      end
    rescue SystemCallError => e
      record["port helper: #{e.message}", "warn", fix]
    end
  end
end
