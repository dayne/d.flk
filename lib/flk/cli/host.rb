module Flk
  # flk resume, stop-all, disk, images
  class CLI
    private

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
  end
end
