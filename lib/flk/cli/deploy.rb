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
      pre = pre_deploy_backup(a, cfg)
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
      end
      Image.prune(a, keep: cfg.keep_releases)

      puts Util.green("\n✔ Deployed #{a.name} v#{version}")
      if (port = mconfig["internal_port"])
        a.machines.each { |m| puts "   #{m.name}  http://#{m.ip}:#{port}" }
      end
      next_step("flk status", "flk logs", "flk context")
    end

    # The same warnings as strings, for JSON ([] without a readable config).
    # A deploy that failed before it touched any machine (the build, or a
    # check before the roll): the cause, then a last line that says nothing
    # changed, for people who'd otherwise stop the machine to be safe.
    def stopped_before_machines!(a, stage, cause)
      warn cause.message
      note = unchanged_note(a)
      Events.emit("deploy.failed", app: a.name, release: a.current_release&.dig("version"),
                                   detail: "#{stage} failed; machines unchanged (#{note}): #{cause.message.lines.first.to_s.chomp}")
      fix = stage == "build" ? "flk deploy (after fixing the build)" : "flk deploy (after fixing that)"
      raise Error.new("#{stage} failed; machines unchanged (#{note})", next_steps: [fix, "flk status"])
    end

    def unchanged_note(a)
      vs = a.machines.map(&:release).uniq.sort
      vs.empty? ? "no machines yet" : "still on #{vs.map { "v#{_1}" }.join(' and ')}"
    end

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
        steps = ["flk logs -i #{m.id} --no-tail", "flk status"]
        steps << "flk releases rollback" if done.any?
        raise Error.new(msg, next_steps: steps)
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
  end
end
