module Flk
  # What flk will do with a built rootfs, read from the image itself (no
  # boot): how it boots, who the app runs as and whether init can switch
  # to that user, what the mounts land on. For `flk build` (and its
  # warnings); deploy uses `user` to own new volumes.
  module ImageReport
    PATH_DIRS = %w[/usr/local/sbin /usr/local/bin /usr/sbin /usr/bin /sbin /bin].freeze

    module_function

    # Who the release's app runs as (its image's USER, as /flk/init reads
    # it): { name:, uid:, gid:, root: }; uid nil when a name can't be found
    # in the image's /etc/passwd. Like init: no group means the passwd
    # entry's, or for a numeric user without one, the same number.
    def user(img)
      u = (VolFS.read(img, "/flk/user").strip rescue "")
      return { name: "root", uid: 0, gid: 0, root: true } if ["", "root", "0", "0:0"].include?(u)
      usr, grp = u.split(":", 2)
      table = lambda do |file|
        (VolFS.read(img, file) rescue "").lines.map { _1.chomp.split(":") }
      end
      pw = table.call("/etc/passwd").find { usr.match?(/\A\d+\z/) ? _1[2] == usr : _1[0] == usr }
      uid = usr.match?(/\A\d+\z/) ? usr.to_i : pw&.[](2)&.to_i
      gid = if grp.nil? then pw ? pw[3].to_i : uid
            elsif grp.match?(/\A\d+\z/) then grp.to_i
            else table.call("/etc/group").find { _1[0] == grp }&.[](2)&.to_i
            end
      uid = nil if gid.nil?
      { name: u, uid: uid, gid: gid, root: uid&.zero? || false }
    end

    # path with its symlinks followed, inside the image: [path, entry], or
    # nil when it (or a link on the way) doesn't exist.
    def resolve(img, path, depth = 0)
      e = VolFS.stat(img, path) or return nil
      return [VolFS.clean(path), e] unless e.type == "symlink"
      return nil if depth > 8
      t = VolFS.readlink(img, path) or return nil
      resolve(img, File.expand_path(t, File.dirname(VolFS.clean(path))), depth + 1)
    end

    # The first `name` on init's PATH, resolved: [path, entry] or nil.
    def which(img, name)
      PATH_DIRS.each do |d|
        r = resolve(img, File.join(d, name)) and return r
      end
      nil
    end

    # Does the program `name` know `flag`? A busybox applet doesn't (its
    # setpriv has no --reuid, its chroot no --userspec); a real program's
    # binary has the flag's name in its help text.
    def knows?(img, name, flag)
      path, e = which(img, name)
      return false unless e&.type == "file" && File.basename(path) != "busybox" && e.size < 4 * 1024**2
      (VolFS.read(img, path) rescue "").include?(flag)
    end

    # How init switches to the image's USER, in init.sh's order: util-linux
    # "setpriv", flk-agent ("agent": also the static init), coreutils
    # "chroot", or "none" (it runs the app as root, with one line in the
    # boot log). nil when the app runs as root anyway.
    def switch(img, usr, static_init)
      return nil if usr[:root]
      return "agent" if static_init
      return "setpriv" if knows?(img, "setpriv", "reuid")
      return "agent" if VolFS.stat(img, "/flk/agent")
      return "chroot" if knows?(img, "chroot", "userspec")
      "none"
    end

    def report(img, cfg, built)
      icfg = built["image_config"] || {}
      static = VolFS.stat(img, "/bin/sh").nil?
      usr = user(img)
      argv = Image.argv_for(cfg, icfg)
      {
        "app" => cfg.app, "config_path" => File.expand_path(cfg.path),
        "source" => built["source"], "tag" => built["tag"], "build_log" => built["log"],
        "image_bytes" => image_bytes(built["tag"]),
        "rootfs_bytes" => File.size(img), "rootfs_used_bytes" => File.stat(img).blocks * 512,
        "init" => static ? "static" : "shell",
        "agent" => !VolFS.stat(img, "/flk/agent").nil?,
        "cmd" => argv,
        "cmd_from" => if cfg.entrypoint || cfg.cmd then "flk.toml"
                      elsif Array(icfg["Entrypoint"]).any? || Array(icfg["Cmd"]).any? then "image"
                      else "default"
                      end,
        "workdir" => icfg["WorkingDir"].to_s.empty? ? "/" : icfg["WorkingDir"],
        "env" => Array(icfg["Env"]).map { _1.split("=", 2).first }.grep(ENV_KEY),
        "user" => { "name" => usr[:name], "uid" => usr[:uid], "gid" => usr[:gid], "root" => usr[:root],
                    "switch" => switch(img, usr, static) },
        "mounts" => Array(cfg.machine_config["mount_specs"]).map { mount(img, _1) },
        "warnings" => []
      }
    end

    # What a volume mounted at destination hides and how its owner is set:
    # { source, destination, in_image, uid, gid, entries }.
    def mount(img, spec)
      dest = spec["destination"]
      _path, e = resolve(img, dest)
      h = { "source" => spec["source"], "destination" => dest, "in_image" => !e.nil? }
      return h unless e
      entries = e.dir? ? VolFS.list(img, dest).reject { _1.name == "lost+found" }.size : nil
      h.merge("type" => e.type, "uid" => e.uid, "gid" => e.gid, "entries" => entries)
    end

    def image_bytes(tag)
      out, st = Open3.capture2e(Image.engine, "image", "inspect", "--format", "{{.Size}}", tag)
      st.success? && out.strip.match?(/\A\d+\z/) ? out.strip.to_i : nil
    end
  end
end
