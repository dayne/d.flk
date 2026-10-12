module Flk
  # Dockerfile or [build] image -> OCI image -> ext4 rootfs with /flk/init.
  module Image
    module_function

    def engine
      ENV["FLK_ENGINE"] || %w[podman docker].find { Util.which(_1) } ||
        raise(Error, "need podman or docker to build images")
    end

    def build(app, cfg, version, image_override: nil)
      eng = engine
      tag = "flk.local/#{app.name}:v#{version}"
      src = image_override || cfg.image

      if src
        unless system(eng, "image", "inspect", src, out: File::NULL, err: File::NULL)
          puts "==> Pulling #{src}"
          Util.sh!(eng, "pull", src)
        end
        Util.run!(eng, "tag", src, tag)
      else
        df = File.expand_path(cfg.dockerfile, cfg.dir)
        raise Error, "no [build] image and no #{cfg.dockerfile} in #{cfg.dir}" unless File.exist?(df)
        puts "==> Building #{tag} with #{eng}"
        args = cfg.build_args.flat_map { |k, v| ["--build-arg", "#{k}=#{v}"] }
        Util.sh!(eng, "build", "-t", tag, "-f", df, *args, cfg.dir)
      end

      icfg = JSON.parse(Util.run!(eng, "image", "inspect", "--format", "{{json .Config}}", tag)) || {}
      out = File.join(app.dir, "images", "v#{version}.ext4")

      Dir.mktmpdir("flk-overlay") do |ov|
        write_overlay(File.join(ov, "flk"), cfg, icfg)
        puts "==> Converting image to rootfs"
        Util.sh!(File.join(LIBEXEC, "flk-build-rootfs"), eng, tag, ov, out, cfg.rootfs_extra_mb.to_s)
      end

      { "version" => version, "tag" => tag, "path" => out, "source" => src || cfg.dockerfile, "created_at" => Util.now }
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

    def prune(app, keep: 2)
      imgs = Dir.glob(File.join(app.dir, "images", "v*.ext4")).sort_by { File.basename(_1)[/\d+/].to_i }
      imgs[0...-keep].to_a.each { FileUtils.rm_f(_1) }
    end
  end
end
