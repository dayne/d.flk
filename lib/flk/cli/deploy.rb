module Flk
  # flk launch and deploy: building a release and rolling machines onto it
  class CLI
    private

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
      pre = o[:no_backup] ? nil : pre_deploy_backup(a, cfg)
      puts Util.yellow("Skipping the before_deploy backups (--no-backup)") if o[:no_backup] && cfg.backup["before_deploy"]
      version = (a.meta["releases"].last&.dig("version") || 0) + 1
      puts "==> Release v#{version} of #{a.name}"
      recorded = rolling = false
      stage = "build"
      begin
        rel = Image.build(a, cfg, version, image_override: o[:image])
        stage = "deploy"
        Util.with_lock do
          machines = deploy_capacity!(a, mconfig) # again: things may have changed during the build
          # Record the release only once its machines can be rolled, so a
          # failed precondition never leaves a release with nothing on it.
          meta = a.meta
          meta["releases"] << rel
          meta["config_path"] = File.expand_path(cfg.path)
          a.save_meta(meta)
          recorded = rolling = true
          roll!(a, rel, mconfig, machines, no_rollback: o[:no_rollback], pre_backup: pre)
        end
      rescue Error => e
        raise if rolling
        stopped_before_machines!(a, stage, e)
      rescue Interrupt
        warn "\nInterrupted: #{stage} stopped; machines unchanged (#{unchanged_note(a)})" unless rolling
        raise
      ensure
        unless recorded
          FileUtils.rm_f(File.join(a.dir, "images", "v#{version}.ext4"))
          Image.untag(a.name) { _1 == "v#{version}" }
        end
        copy_deploy_backups(a, version, pre) if recorded
      end
      Image.prune(a, keep: cfg.keep_releases)

      puts Util.green("\n✔ Deployed #{a.name} v#{version}")
      if (port = mconfig["internal_port"])
        a.machines.each { |m| puts "   #{m.name}  http://#{m.ip}:#{port}" }
      end
      next_step("flk status", "flk logs", "flk context")
    end

    def cmd_build(_args, o)
      cfg = config
      if @app_name && @app_name != cfg.app
        raise Error, "-a #{@app_name} doesn't match app '#{cfg.app}' in #{File.basename(cfg.path)}"
      end
      config_warnings(cfg) unless o[:json]
      t0 = Time.now
      stdout = $stdout
      $stdout = $stderr if o[:json] # the build's progress; stdout is the JSON
      rep = begin
        Image.trial_build(cfg, image_override: o[:image]) do |b|
          r = ImageReport.report(b["rootfs"], cfg, b)
          a = App.new(cfg.app)
          r["warnings"] += ImageReport.volume_warnings(r, a.volumes) if a.exists?
          r
        end
      rescue Error => e
        raise unless o[:json]
        $stdout = stdout
        # stdout stays JSON for scripts; the words go to stderr as always
        fail = { "ok" => false, "app" => cfg.app, "error" => e.message, "seconds" => (Time.now - t0).round(1) }
        fail.merge!("said" => e.said, "step" => e.step, "build_log" => e.log) if e.is_a?(Image::BuildFailed)
        puts JSON.pretty_generate(fail)
        raise
      ensure
        $stdout = stdout
      end
      rep = { "ok" => true }.merge(rep)
      rep["seconds"] = (Time.now - t0).round(1)
      return puts(JSON.pretty_generate(rep)) if o[:json]
      print_build_report(rep)
      a = App.new(cfg.app)
      a.exists? ? next_step("flk deploy") : next_step("flk launch --no-deploy", "flk launch")
    end

    def print_build_report(r)
      mb = ->(b) { b ? "#{(b / 1024.0**2).round}MB" : "?" }
      u = r["user"]
      puts Util.green("\n✔ Built #{r['app']} from #{r['source']} in #{r['seconds']}s") +
           " (not a release): image #{mb[r['image_bytes']]}, rootfs #{mb[r['rootfs_used_bytes']]} used of #{mb[r['rootfs_bytes']]}"
      puts "  boots     #{r['init'] == 'static' ? "flk's static init (no /bin/sh in the image)" : '/flk/init (shell)'}"
      puts "  runs      #{r['cmd'].map { _1.match?(/[\s"']/) || _1.empty? ? _1.inspect : _1 }.join(' ')}#{'   (no CMD: the default)' if r['cmd_from'] == 'default'}"
      puts "  in        #{r['workdir']}"
      who = u["root"] ? "root" : "#{u['name']} (#{u['uid'] || '?'}:#{u['gid'] || '?'})"
      how = { "agent" => ", switched by flk-agent", "setpriv" => ", switched by setpriv", "chroot" => ", switched by chroot --userspec",
              "none" => ", but the image can't switch to it: it runs as root" }[u["switch"]]
      puts "  as        #{who}#{how}"
      puts "  exec      #{r['agent'] ? 'flk exec and ssh console work' : 'no flk-agent (needs Go on the host): no flk exec or ssh console'}"
      r["mounts"].each do |m|
        what = if !m["in_image"] then "not in the image (flk makes it)"
               elsif m["type"] != "dir" then "a #{m['type']} in the image, not a directory"
               else "owned #{m['uid']}:#{m['gid']}#{m['entries'].to_i.positive? ? ", #{m['entries']} entr#{m['entries'] == 1 ? 'y' : 'ies'} the volume hides" : ', empty'}"
               end
        puts "  mount     #{m['destination']} (#{m['source']}): #{what}"
      end
      r["warnings"].each { warn Util.yellow("  ⚠ #{_1['message']}#{"\n    fix: #{_1['fix']}" if _1['fix']}") }
      puts "  Build log: #{r['build_log']}"
    end

    # A deploy that failed before it touched any machine (the build, or a
    # check before the roll): the cause, then a last line that says nothing
    # changed, for people who'd otherwise stop the machine to be safe.
    def stopped_before_machines!(a, stage, cause)
      warn cause.message
      note = unchanged_note(a)
      # the event's detail stays one short line: the build's own first error
      # line ("ERROR: Steam served build ..."), not podman's command line
      why = if cause.is_a?(Image::BuildFailed) then cause.first_line
            else cause.message.lines.first.to_s.chomp.sub(/\Acommand failed: (\S+) (\S+).*/) { "#{File.basename($1)} #{$2} failed" }
            end
      Events.emit("deploy.failed", app: a.name, release: a.current_release&.dig("version"),
                                   detail: "#{stage} failed; machines unchanged (#{note}): #{why}",
                                   log: cause.respond_to?(:log) ? cause.log : nil)
      fix = stage == "build" ? "flk deploy (after fixing the build)" : "flk deploy (after fixing that)"
      raise Error.new("#{stage} failed; machines unchanged (#{note})", next_steps: [fix, "flk status"])
    end

    def unchanged_note(a)
      vs = a.machines.map(&:release).uniq.sort
      vs.empty? ? "no machines yet" : "still on #{vs.map { "v#{_1}" }.join(' and ')}"
    end

    # The same warnings as strings, for JSON ([] without a readable config).
    def warning_strings(cfg)
      return [] unless cfg
      cfg.unknown_keys.map { "unknown key #{_1}; flk ignores it" } + cfg.mount_problems
    rescue StandardError
      []
    end

    # Warnings about the config that don't stop anything: unknown keys.
    def config_warnings(cfg)
      warning_strings(cfg).each do |w|
        warn Util.yellow("⚠ #{File.basename(cfg.path)}: #{w}")
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
    # A machine whose release failed its health checks never had anything
    # good on its volumes, so a verify hook failing there only warns
    # (../valheim.flk BUGS.flk.md #5: the deploy that would fix a first
    # start couldn't get past it).
    def backup_before_deploy(m, rel, pre)
      soft = m.app.release(m.release)&.dig("status") == "failed"
      m.app.volumes.select { _1["attached_machine"] == m.id }.map do |v|
        dst = backup_one(m.app, v, pre[:root], pre[:plan], pre[:keep], pre[:hook_dir], check: true, fast: true, soft_verify: soft,
                         extra: { "reason" => "before_deploy", "release" => m.release, "for_release" => rel["version"] })
        { "machine" => m.id, "volume" => v["name"], "volume_id" => v["id"], "file" => File.basename(dst), "path" => dst }
      end
    end

    # The release's before_deploy backups go to backup_copy_to too, like any
    # backup, but only once the roll is over (succeeded or not): copying
    # during it would add to the downtime (../enshrouded.flk BUGS.flk.md #2).
    # A copy that fails only warns: the deploy is done, the backup is fine.
    def copy_deploy_backups(a, version, pre)
      return unless pre && (dest = Host.settings["backup_copy_to"])
      taken = Array(a.release(version)&.dig("backups"))
      return if taken.empty?
      dest = Backup.copy_dest!(dest)
      taken.each do |t|
        v = a.volumes.find { _1["id"] == t["volume_id"] } or next
        begin
          copy_one(a, v, pre[:root], dest, t["file"], Backup.copy_keep(nil))
        rescue Error => e
          warn Util.yellow("  ⚠ #{e.message}; the backup itself is fine (again: flk volumes copy #{v['name']} --backup #{t['file']})")
          Events.emit("backup.copy_failed", app: a.name, machine: t["machine"], detail: "#{v['name']}: #{e.message}")
        end
      end
    rescue Error => e
      warn Util.yellow("  ⚠ before_deploy backups not copied: #{e.message}")
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
          m = create_machine(a, rel, mconfig, checks_follow: checks.any?)
          next if (why = health_failure(m, checks)).nil?
          fail_release!(a, rel, why)
          raise Error.new("v#{rel['version']} failed its health checks on new machine #{m.id}: #{why}. " \
                          "Nothing older to go back to; fix it and deploy again (logs: flk logs -i #{m.id} --no-tail)",
                          next_steps: ["flk logs -i #{m.id} --no-tail", "flk deploy (after fixing it)"])
        end
        return
      end
      puts "==> Updating #{machines.size} machine#{'s' if machines.size > 1} (rolling)"
      done = []
      machines.each do |m|
        before = { "release" => m.release, "config" => m.h["config"] }
        taken = []
        was_running = m.running?
        update_machine(m, rel, mconfig, checks_follow: checks.any?) do
          if pre_backup
            begin
              taken = backup_before_deploy(m, rel, pre_backup)
            rescue Error => e
              backup_stopped_the_roll!(a, rel, m, was_running, e, done)
            end
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
        steps = ["flk logs -i #{m.id} --no-tail", "flk status"]
        steps << "flk releases rollback" if done.any?
        raise Error.new(msg, next_steps: steps)
      end
    end

    # A before_deploy backup failed with m stopped and still on its old
    # release: start it again (if it was running), and stop the roll. It
    # used to stay down.
    def backup_stopped_the_roll!(a, rel, m, was_running, cause, done)
      fail_release!(a, rel, "the before_deploy backup of #{m.id} failed")
      boot(m, "Machine #{m.id} [#{m.name}] started again on v#{m.release} (deploy stopped)") if was_running
      msg = "the before_deploy backup of #{m.id} [#{m.name}] failed, so it stays on v#{m.release}" \
            "#{was_running ? ' (running again)' : ''}: #{cause.message}"
      msg += "; #{done.map(&:id).join(', ')} already moved to v#{rel['version']} (back: flk releases rollback)" if done.any?
      raise Error.new(msg, next_steps: ["flk deploy --no-backup (deploy without the backup)",
                                        "fix [flk.backup] verify, then flk deploy"])
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
        res = ::Net::HTTP.start(m.ip, c["port"], open_timeout: 2, read_timeout: 5) { _1.get(c["path"]) }
        res.code.to_i.between?(200, 399)
      when "log"
        log = m.path("console.log")
        tail = File.open(log, "rb") { |f| f.seek([f.size - 262_144, 0].max); f.read }.to_s
        since = tail.rindex("--- flk: booting") || 0
        # serial console lines end in "\r\r\n": without the \r, `$` works
        # (d.flkforge BUGS.flk.md #2), as in console --wait-log
        tail[since..].scrub.delete("\r").match?(Regexp.new(c["match"]))
      end
    rescue SystemCallError, IOError, ::Net::OpenTimeout, ::Net::ReadTimeout, ::Net::HTTPBadResponse, EOFError
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
                   "re-run: #{Util.setup_host_cmd("FLK_TAPS=#{Net::POOL * 2}")}"
    end
  end
end
