module Flk
  # flk volumes backup, copy, backups, verify, restore
  class CLI
    private

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
  end
end
