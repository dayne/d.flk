module Flk
  # Dockerfile or [build] image -> OCI image -> ext4 rootfs with /flk/init.
  module Image
    module_function

    # A user-level drop-in adds to the system registries.conf; a user-level
    # registries.conf would replace it (and its short-name aliases).
    REGISTRIES_DROPIN = "~/.config/containers/registries.conf.d/50-flk-docker-io.conf"
    REGISTRIES_FIX = "mkdir -p #{File.dirname(REGISTRIES_DROPIN)} && " \
                     "echo 'unqualified-search-registries = [\"docker.io\"]' > #{REGISTRIES_DROPIN}"

    def engine
      ENV["FLK_ENGINE"] || %w[podman docker].find { Util.which(_1) } ||
        raise(Error, "need podman or docker to build images")
    end

    def podman?(eng = engine) = File.basename(eng) == "podman"

    # Can podman resolve `FROM ruby:3.3`? Ubuntu/Debian ship no search
    # registries, so only aliased names (alpine, debian...) work there.
    def short_names_resolve?
      out, st = Open3.capture2e(engine, "info", "--format", "{{json .Registries}}")
      st.success? && Array(JSON.parse(out)["search"]).any?
    rescue JSON::ParserError, SystemCallError
      false
    end

    # Runs a build/pull, turning podman's short-name failure into the fix.
    def engine_run!(*cmd)
      out, st = Util.sh_capture(*cmd)
      return if st.success?
      if (name = out[/short-name "([^"]+)" did not resolve/, 1])
        full = name.include?("/") ? "docker.io/#{name}" : "docker.io/library/#{name}"
        raise Error, "podman can't resolve the short image name \"#{name}\": no unqualified-search registries are configured.\n" \
                     "Fix it once for your user (no root):\n  #{REGISTRIES_FIX}\n" \
                     "or use the full name, e.g. FROM #{full}"
      end
      raise Error, "command failed: #{cmd.shelljoin}"
    end

    def build(app, cfg, version, image_override: nil)
      eng = engine
      tag = "flk.local/#{app.name}:v#{version}"
      src = image_override || cfg.image

      if src
        unless system(eng, "image", "inspect", src, out: File::NULL, err: File::NULL)
          puts "==> Pulling #{src}"
          engine_run!(eng, "pull", src)
        end
        Util.run!(eng, "tag", src, tag)
      else
        df = File.expand_path(cfg.dockerfile, cfg.dir)
        raise Error, "no [build] image and no #{cfg.dockerfile} in #{cfg.dir}" unless File.exist?(df)
        puts "==> Building #{tag} with #{eng}"
        args = cfg.build_args.flat_map { |k, v| ["--build-arg", "#{k}=#{v}"] }
        before = storage_containers
        begin
          engine_run!(eng, "build", "--force-rm", "-t", tag, "-f", df, *args, cfg.dir)
        rescue Exception # rubocop:disable Lint/RescueException -- Ctrl-C too
          leftovers_note(storage_containers - before)
          raise
        end
      end

      icfg = JSON.parse(Util.run!(eng, "image", "inspect", "--format", "{{json .Config}}", tag)) || {}
      out = File.join(app.dir, "images", "v#{version}.ext4")

      Dir.mktmpdir("flk-overlay") do |ov|
        write_overlay(File.join(ov, "flk"), cfg, icfg)
        puts "==> Converting image to rootfs"
        Util.sh!(File.join(LIBEXEC, "flk-build-rootfs"), eng, tag, ov, out, cfg.rootfs_extra_mb.to_s)
      end

      { "version" => version, "tag" => tag, "path" => out, "source" => src || cfg.dockerfile, "created_at" => Util.now,
        "config" => cfg.machine_config }
    end

    # The image's ENTRYPOINT/CMD/ENV/WORKDIR/USER, baked in as plain
    # shell files so the guest init needs nothing beyond /bin/sh.
    def write_overlay(fdir, cfg, icfg)
      FileUtils.mkdir_p(fdir)
      FileUtils.cp(File.join(SHARE, "init.sh"), File.join(fdir, "init"))

      ep = cfg.entrypoint || Array(icfg["Entrypoint"])
      cmd = cfg.cmd || (cfg.entrypoint ? [] : Array(icfg["Cmd"]))
      argv = ep + cmd
      argv = ["/bin/sh"] if argv.empty?

      File.write(File.join(fdir, "cmd"), "#!/bin/sh\nexec #{argv.shelljoin}\n")
      File.write(File.join(fdir, "image.env"), Array(icfg["Env"]).filter_map { |kv|
        k, v = kv.split("=", 2)
        "export #{k}=#{v.to_s.shellescape}\n" if k.match?(ENV_KEY)
      }.join)
      File.write(File.join(fdir, "workdir"), icfg["WorkingDir"].to_s.empty? ? "/" : icfg["WorkingDir"])
      File.write(File.join(fdir, "user"), icfg["User"].to_s)
      File.chmod(0o755, File.join(fdir, "init"), File.join(fdir, "cmd"))
    end

    def repo(app_name) = "flk.local/#{app_name}"

    # Keep the images (rootfs file and engine tag) of the last `keep`
    # releases that didn't fail, and of any release a machine is on.
    def prune(app, keep: 2)
      ok = app.meta["releases"].reject { _1["status"] == "failed" }.last(keep).map { _1["version"] }
      keep_v = (ok + app.machines.map(&:release)).uniq
      Dir.glob(File.join(app.dir, "images", "v*.ext4")).each do |f|
        FileUtils.rm_f(f) unless keep_v.include?(File.basename(f)[/\d+/].to_i)
      end
      untag(app.name) { !keep_v.include?(_1.delete_prefix("v").to_i) }
    end

    # podman's build containers ("working containers", buildah's, shown by
    # `podman ps --external` in state Storage) as [id, name, created_at].
    # An interrupted build leaves its own behind, still mounted.
    def storage_containers
      return [] unless podman?
      out, st = Open3.capture2e(engine, "ps", "-a", "--external", "--format", "{{.ID}}\t{{.Names}}\t{{.Status}}\t{{.CreatedAt}}")
      return [] unless st.success?
      out.lines.map { _1.chomp.split("\t") }.select { _1[2].to_s.match?(/storage/i) }.map { [_1[0], _1[1], _1[3]] }
    rescue Error, SystemCallError
      []
    end

    # Never removed by flk: another build may be running right now, and its
    # containers look the same. The command is printed instead.
    def leftovers_note(rows)
      return if rows.empty?
      warn Util.yellow("The interrupted build left #{rows.size} build container#{'s' if rows.size > 1} " \
                       "(#{rows.map { _1[1] }.join(', ')}), still mounted. Remove them with:\n  #{cleanup_command(rows)}")
    end

    def cleanup_command(rows)
      ids = rows.map(&:first).join(" ")
      Util.which("buildah") ? "buildah rm #{ids}" : "podman rm --force --storage #{ids}"
    end

    # flk's vN tags for an app (never other tags someone added by hand).
    def tags(app_name)
      out, st = Open3.capture2e(engine, "images", "--format", "{{.Tag}}", repo(app_name))
      st.success? ? out.split.grep(/\Av\d+\z/).uniq : []
    rescue Error, SystemCallError
      []
    end

    # Untags (the image goes too once nothing else names it). Returns the count.
    def untag(app_name, &keep_if_false)
      gone = tags(app_name).select { keep_if_false ? keep_if_false.call(_1) : true }
      gone.each { system(engine, "rmi", "#{repo(app_name)}:#{_1}", out: File::NULL, err: File::NULL) }
      gone.size
    end

    # App names with flk.local tags but no app directory: leftovers from
    # before apps destroy removed tags.
    # Every image under flk.local/ ([{ repo, tag, id, size_bytes,
    # created_at }]), one entry per tag; [] without an engine.
    def list
      out, st = Open3.capture2e(engine, "images", "--format", "{{.Repository}} {{.Tag}} {{.ID}}")
      return [] unless st.success?
      rows = out.lines.map(&:split).select { _1.size == 3 && _1[0].start_with?("flk.local/") }.uniq
      short = ->(id) { id.delete_prefix("sha256:")[0, 12] }
      ids = rows.map { short[_1[2]] }.uniq
      info = ids.empty? ? [] : JSON.parse(Util.run!(engine, "image", "inspect", *ids))
      by_id = info.to_h { [short[_1["Id"]], _1] }
      rows.map do |repo, tag, id|
        i = by_id[short[id]] || {}
        { "repo" => repo, "tag" => tag, "id" => short[id], "size_bytes" => i["Size"],
          "created_at" => (Time.parse(i["Created"].to_s).utc.iso8601 rescue nil) }
      end
    rescue Error, SystemCallError, JSON::ParserError
      []
    end

    def orphan_repos
      out, st = Open3.capture2e(engine, "images", "--format", "{{.Repository}}")
      return [] unless st.success?
      out.split.filter_map { _1.delete_prefix("flk.local/") if _1.start_with?("flk.local/") }.uniq
         .reject { App::NAME_RE.match?(_1) && App.new(_1).exists? }
    rescue Error, SystemCallError
      []
    end
  end
end
