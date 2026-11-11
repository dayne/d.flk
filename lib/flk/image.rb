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

    # A build step that failed: what the build itself said (its error lines,
    # not the podman command line), and where the whole output is.
    # (../valheim.flk BUGS.flk.md #2: the cause was 40 lines up, then gone.)
    class BuildFailed < Error
      attr_reader :said, :step
      attr_accessor :log

      def initialize(said, step, hint = "")
        @said = said
        @step = step
        @hint = hint
        super(nil)
      end

      # For the deploy.failed event: one line, the build's own words.
      def first_line = (said.first || step).to_s.strip[0, 200]

      def message
        parts = []
        parts << "The build said:\n#{said.map { "  #{_1}" }.join("\n")}" if said.any?
        parts << step
        parts << "Build log: #{log}" if log
        parts.join("\n") + @hint
      end
      alias to_s message
    end

    FAILED_LOGS_KEPT = 3

    def log_dir(app) = File.join(app.dir, "builds")

    # The build log of release vN (nil when there's none: a rollback, or a
    # release from before flk kept them).
    def build_log(app, version)
      f = File.join(log_dir(app), "v#{version}.log")
      File.exist?(f) ? f : nil
    end

    # Runs a build/pull/conversion step, into the log too. Turns podman's
    # short-name failure into the fix, and any other failure into what the
    # build said.
    # what: the step, when the output doesn't name it ("podman build failed").
    def engine_run!(*cmd, log: nil, what: nil)
      out, st = Util.sh_capture(*cmd, tee: log)
      return if st.success?
      if (name = out[/short-name "([^"]+)" did not resolve/, 1])
        full = name.include?("/") ? "docker.io/#{name}" : "docker.io/library/#{name}"
        raise Error, "podman can't resolve the short image name \"#{name}\": no unqualified-search registries are configured.\n" \
                     "Fix it once for your user (no root):\n  #{REGISTRIES_FIX}\n" \
                     "or use the full name, e.g. FROM #{full}"
      end
      said, step = explain_failure(out, what || "#{File.basename(cmd[0])} #{cmd[1]} failed")
      raise BuildFailed.new(said, step, build_hint(out))
    end

    ERROR_LINE = /\A\s*(?:#\d+ )?(?:ERROR|Error|error|FATAL|Fatal|fatal)\b[:!]?|\Aflk: /
    STEP_LINE = /\A(?:\[\d+\/\d+\] )?STEP (\d+\/\d+): /

    # The lines worth showing from a failed step's output, and one line
    # naming the step: [said, step]. podman marks steps "[1/2] STEP 3/4: RUN
    # ..." and ends with `Error: building at STEP "RUN ...": ...: exit
    # status 1`; error lines are taken from the failing step only (earlier
    # steps' warnings aren't the cause), else its last lines.
    def explain_failure(out, fallback)
      lines = out.lines.map { _1.chomp.sub(/\s+\z/, "") }
      at = lines.rindex { _1.match?(STEP_LINE) }
      fin = lines.rindex { _1.start_with?("Error: building at STEP") }
      body = lines[(at ? at + 1 : 0)...(fin || lines.size)].reject(&:empty?)
      said = body.grep(ERROR_LINE)
      said = body.last(10) if said.empty?
      said = said.last(10).map { _1.size > 300 ? "#{_1[0, 300]}…" : _1 }
      step = if fin && (m = lines[fin].match(/\AError: building at STEP "(.*)": (?:.*: )?(.+)\z/))
               n = at && lines[at][STEP_LINE, 1]
               text = m[1].size > 60 ? "#{m[1][0, 60]}…" : m[1]
               "failed at STEP #{n ? "#{n} " : ''}(#{text}): #{m[2]}"
             else
               fallback
             end
      [said, step]
    end

    # Known Dockerfile mistakes in the build output, and their fix.
    def build_hint(out)
      return "" unless (id = out[/groupadd: GID '?(\d+)'? already exists/, 1] || out[/useradd: UID (\d+) is not unique/, 1])
      "\nHint: the base image already has a user or group with ID #{id}; ubuntu:23.04 and later ship " \
        "user `ubuntu` as 1000:1000. Rename it instead (usermod -l NEW -d /home/NEW -m ubuntu && " \
        "groupmod -n NEW ubuntu), or remove it first (userdel -r ubuntu)."
    end

    # Builds release vN's image and rootfs, saving all the output in
    # builds/vN.log. A failed build's log becomes vN-failed-TIME.log (the
    # next try reuses vN), and the newest FAILED_LOGS_KEPT of those are kept.
    def build(app, cfg, version, image_override: nil)
      FileUtils.mkdir_p(log_dir(app))
      path = File.join(log_dir(app), "v#{version}.log")
      File.open(path, "w") do |log|
        log.sync = true
        log.puts "# flk: build of #{app.name} v#{version}, #{Util.now}"
        build_into(app, cfg, version, image_override, log)
      end
    rescue Error => e
      failed = File.join(log_dir(app), "v#{version}-failed-#{Time.now.utc.strftime('%Y%m%dT%H%M%S%LZ')}.log")
      begin
        File.rename(path, failed)
        e.log = failed if e.respond_to?(:log=)
      rescue SystemCallError
        nil
      end
      prune_failed_logs(app)
      raise
    end

    def build_into(app, cfg, version, image_override, log)
      tag = "flk.local/#{app.name}:v#{version}"
      out = File.join(app.dir, "images", "v#{version}.ext4")
      src = make_image(app.name, cfg, tag, image_override, log, "flk.release" => version)
      make_rootfs(cfg, tag, out, log)
      { "version" => version, "tag" => tag, "path" => out, "source" => src || cfg.dockerfile, "created_at" => Util.now,
        "config" => cfg.machine_config }
    end

    # Pulls src (an image name) or builds cfg's Dockerfile, as tag. Returns
    # src (nil for a Dockerfile).
    def make_image(name, cfg, tag, src, log, labels = {})
      eng = engine
      src ||= cfg.image
      if src
        unless system(eng, "image", "inspect", src, out: File::NULL, err: File::NULL)
          puts "==> Pulling #{src}"
          engine_run!(eng, "pull", src, log: log)
        end
        Util.run!(eng, "tag", src, tag)
      else
        df = File.expand_path(cfg.dockerfile, cfg.dir)
        raise Error, "no [build] image and no #{cfg.dockerfile} in #{cfg.dir}" unless File.exist?(df)
        puts "==> Building #{tag} with #{eng}"
        args = cfg.build_args.flat_map { |k, v| ["--build-arg", "#{k}=#{v}"] }
        # labels: `podman image prune -a --filter label!=flk.app` spares
        # flk's images (../mud BUGS.flk.md #5)
        labels = { "flk.app" => name }.merge(labels).flat_map { |k, v| ["--label", "#{k}=#{v}"] }
        before = storage_containers
        begin
          engine_run!(eng, "build", "--force-rm", *labels, "-t", tag, "-f", df, *args, cfg.dir, log: log)
        rescue Exception # rubocop:disable Lint/RescueException -- Ctrl-C too
          leftovers_note(storage_containers - before)
          raise
        end
      end
      src
    end

    # Turns image tag into the bootable ext4 out, with flk's overlay (init,
    # agent, the image's command and user). Returns the image's config.
    def make_rootfs(cfg, tag, out, log)
      icfg = JSON.parse(Util.run!(engine, "image", "inspect", "--format", "{{json .Config}}", tag)) || {}
      Dir.mktmpdir("flk-overlay") do |ov|
        write_overlay(File.join(ov, "flk"), cfg, icfg)
        puts "==> Converting image to rootfs"
        engine_run!(File.join(LIBEXEC, "flk-build-rootfs"), engine, tag, ov, out, cfg.rootfs_extra_mb.to_s,
                    log: log, what: "converting the image to a rootfs failed")
      end
      icfg
    end

    # flk build: the image and rootfs a deploy would make, outside any
    # release (tag flk.local/APP:build, rootfs in ROOT/build/APP). One at a
    # time per app. Yields { tag, rootfs, log, source, image_config } and
    # removes the rootfs after; the log stays.
    TRIAL_TAG = "build"

    def trial_dir(name) = File.join(ROOT, "build", name)

    # Every flk build's tag ("flk.local/APP:build"): disposable, so
    # `flk images prune` takes them (their layers stay while a release
    # shares them).
    def trial_tags
      out, st = Open3.capture2e(engine, "images", "--format", "{{.Repository}}:{{.Tag}}")
      st.success? ? out.split.select { _1.start_with?("flk.local/") && _1.end_with?(":#{TRIAL_TAG}") }.uniq : []
    rescue Error, SystemCallError
      []
    end

    # Removes app's flk build (tag, log). For apps destroy.
    def remove_trial(app_name)
      system(engine, "rmi", "#{repo(app_name)}:#{TRIAL_TAG}", out: File::NULL, err: File::NULL)
      FileUtils.rm_rf(trial_dir(app_name))
    end

    def trial_build(cfg, image_override: nil)
      dir = trial_dir(cfg.app)
      FileUtils.mkdir_p(dir)
      File.open(File.join(dir, ".lock"), File::RDWR | File::CREAT, 0o644) do |lock|
        raise Error, "a flk build of #{cfg.app} is already running" unless lock.flock(File::LOCK_EX | File::LOCK_NB)

        path = File.join(dir, "build.log")
        out = File.join(dir, "rootfs.ext4")
        tag = "#{repo(cfg.app)}:#{TRIAL_TAG}"
        src = icfg = nil
        begin
          File.open(path, "w") do |log|
            log.sync = true
            log.puts "# flk: build of #{cfg.app} (not a release), #{Util.now}"
            src = make_image(cfg.app, cfg, tag, image_override, log, "flk.build" => "1")
            icfg = make_rootfs(cfg, tag, out, log)
          end
          yield({ "tag" => tag, "rootfs" => out, "log" => path, "source" => src || cfg.dockerfile, "image_config" => icfg })
        rescue Error => e
          e.log = path if e.respond_to?(:log=)
          raise
        ensure
          FileUtils.rm_f(out)
        end
      end
    end

    # The image's ENTRYPOINT/CMD/ENV/WORKDIR/USER, baked in as plain
    # shell files so the guest init needs nothing beyond /bin/sh.
    def write_overlay(fdir, cfg, icfg)
      FileUtils.mkdir_p(fdir)
      FileUtils.cp(File.join(SHARE, "init.sh"), File.join(fdir, "init"))
      if (agent = Agent.ensure!)
        FileUtils.cp(agent, File.join(fdir, "agent"))
        File.chmod(0o755, File.join(fdir, "agent"))
      end

      argv = argv_for(cfg, icfg)

      File.write(File.join(fdir, "cmd"), "#!/bin/sh\nexec #{argv.shelljoin}\n")
      File.write(File.join(fdir, "cmd.json"), JSON.generate(argv)) # for the static init (no /bin/sh)
      File.write(File.join(fdir, "image.env"), Array(icfg["Env"]).filter_map { |kv|
        k, v = kv.split("=", 2)
        "export #{k}=#{v.to_s.shellescape}\n" if k.match?(ENV_KEY)
      }.join)
      File.write(File.join(fdir, "workdir"), icfg["WorkingDir"].to_s.empty? ? "/" : icfg["WorkingDir"])
      File.write(File.join(fdir, "user"), icfg["User"].to_s)
      File.chmod(0o755, File.join(fdir, "init"), File.join(fdir, "cmd"))
    end

    # What /flk/cmd runs: [experimental] entrypoint/cmd over the image's.
    # Neither: /bin/sh (an image with neither a CMD nor a shell can't boot).
    def argv_for(cfg, icfg)
      ep = cfg.entrypoint || Array(icfg["Entrypoint"])
      cmd = cfg.cmd || (cfg.entrypoint ? [] : Array(icfg["Cmd"]))
      argv = ep + cmd
      argv.empty? ? ["/bin/sh"] : argv
    end

    def repo(app_name) = "flk.local/#{app_name}"

    # Keep the images (rootfs file and engine tag) of the last `keep`
    # releases that didn't fail, and of any release a machine is on.
    # The releases whose images stay: the last `keep` that didn't fail, and
    # any a machine is on.
    def keep_versions(app, keep)
      ok = app.meta["releases"].reject { _1["status"] == "failed" }.last(keep).map { _1["version"] }
      (ok + app.machines.map(&:release)).uniq
    end

    # Tags of app's images a deploy would prune now. Not ones newer than its
    # last recorded release: a deploy may be building them right now.
    def prunable_tags(app, keep)
      keep_v = keep_versions(app, keep)
      last = app.meta["releases"].last&.dig("version") || 0
      tags(app.name).select { (v = _1[/\Av(\d+)\z/, 1]&.to_i) && v <= last && !keep_v.include?(v) }
    end

    # Untagged images nothing uses (no tag, no child image): what a plain
    # `image prune` removes. Base images and build caches have tags or
    # children, so they stay.
    def dangling_ids
      out, st = Open3.capture2e(engine, "images", "-q", "--filter", "dangling=true")
      st.success? ? out.split.uniq : []
    end

    def prune_dangling! = Util.run!(engine, "image", "prune", "-f")

    def prune(app, keep: 2)
      keep_v = keep_versions(app, keep)
      Dir.glob(File.join(app.dir, "images", "v*.ext4")).each do |f|
        FileUtils.rm_f(f) unless keep_v.include?(File.basename(f)[/\d+/].to_i)
      end
      untag(app.name) { !keep_v.include?(_1.delete_prefix("v").to_i) }
      Dir.glob(File.join(log_dir(app), "v*.log")).each do |f|
        next if f.include?("-failed-")
        FileUtils.rm_f(f) unless keep_v.include?(File.basename(f)[/\d+/].to_i)
      end
      prune_failed_logs(app)
    end

    def prune_failed_logs(app)
      Dir.glob(File.join(log_dir(app), "v*-failed-*.log")).sort_by { File.basename(_1)[/failed-(.*)\.log/, 1] }
         .reverse.drop(FAILED_LOGS_KEPT).each { FileUtils.rm_f(_1) }
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
         .select { tags(_1).any? } # a flk build's :build tag alone isn't a destroyed app's
    rescue Error, SystemCallError
      []
    end
  end
end
