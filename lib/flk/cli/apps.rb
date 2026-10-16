module Flk
  # flk status, releases, apps, config show
  class CLI
    private

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

    def config_show(_args, o)
      if o[:host]
        puts JSON.pretty_generate("file" => Host::PATH, "settings" => Host.settings)
      else
        puts JSON.pretty_generate("file" => config.path, "parsed" => config.data, "machine_config" => config.machine_config,
                                  "warnings" => warning_strings(config))
      end
    end

    def config_set(args, _o)
      updates = args.map do |arg|
        key, _, raw = arg.partition("=")
        raise Error, "expected KEY=VALUE, got: #{arg}" unless arg.include?("=")
        raise Error, "unknown config key '#{key}' (known: #{Host::KEYS.join(', ')})" unless Host::KEYS.include?(key)
        val = Integer(raw) rescue raw
        [key, val]
      end.to_h

      path = Host::PATH
      lines = File.exist?(path) ? File.readlines(path) : []
      updates.each do |key, val|
        toml_val = val.is_a?(Integer) ? val.to_s : "\"#{val.gsub("\\", "\\\\").gsub('"', '\\"')}\""
        new_line = "#{key} = #{toml_val}\n"
        idx = lines.index { |l| l.match?(/\A\s*#{Regexp.escape(key)}\s*=/) }
        idx ? lines[idx] = new_line : lines << new_line
      end

      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, lines.join)
      updates.each { |k, v| puts "#{k} = #{v.inspect}  (#{path})" }
      next_step("flk doctor")
    end
  end
end
