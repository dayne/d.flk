module Flk
  # flk files: files inside a volume or a backup, without mounting
  class CLI
    private

    VOL_REF = /\A([a-z0-9_]{1,30}|vol_\h{16}):(.*)\z/m

    # "VOL:PATH" (or "VOL" when bare is allowed) -> [volume, path], else nil.
    def vol_ref(arg, bare: false)
      md = VOL_REF.match(arg) || (bare && arg.match?(/\A([a-z0-9_]{1,30}|vol_\h{16})\z/) ? [nil, arg, "/"] : nil)
      return nil unless md
      v = app.volumes.find { _1["id"] == md[1] } || app.volumes.find { _1["name"] == md[1] }
      return nil unless v
      [v, VolFS.clean(md[2].empty? ? "/" : md[2])]
    end

    def vol_ref!(arg, bare: false)
      vol_ref(arg, bare: bare) || raise(Error, "'#{arg}' isn't VOL:PATH for a volume of #{app.name} (see: flk volumes list)")
    end

    # The image to read: the volume, or with --backup one of its backups.
    def read_image(v, o)
      return Backup.find!(Backup.root!(o[:to]), app.name, v, o[:backup])["path"] if o[:backup]
      raise Error, "#{v['path']} is missing (is its disk mounted?)" unless File.exist?(v["path"])
      if volume_user(app, v)
        warn Util.yellow("note: #{v['name']} is in use by a running machine; this is what's on disk now " \
                         "(recent writes may still be in the guest's cache; --backup reads a backup)")
      end
      v["path"]
    end

    # Runs the block (returning debugfs commands) with v's machine stopped
    # and flk's lock held, applies them and checks the volume.
    def write_volume(v)
      a = app
      Util.with_lock do
        if (m = volume_user(a, v))
          raise Error, "machine #{m.id} [#{m.name}] is using #{v['name']}; stop it first: flk machine stop #{m.id}"
        end
        raise Error, "#{v['path']} is missing (is its disk mounted?)" unless File.exist?(v["path"])
        VolFS.batch!(v["path"], yield(v["path"]))
        state = VolFS.fsck!(v["path"])
        puts Util.yellow("  e2fsck repaired #{v['name']} afterwards") if state == "repaired"
      end
    end

    def owner_opt(s)
      md = /\A(\d+)(?::(\d+))?\z/.match(s.to_s) or raise Error, "--owner/chown takes numeric UID or UID:GID (got '#{s}')"
      [md[1].to_i, md[2]&.to_i]
    end

    def files_ls(args, o)
      raise Error, "ls takes one VOL[:PATH]" unless args.size == 1
      v, path = vol_ref!(args[0], bare: true)
      rows = VolFS.list(read_image(v, o), path)
      return puts(JSON.pretty_generate(rows.map(&:to_h))) if o[:json]
      return puts("(empty)") if rows.empty?
      Util.table(%w[MODE UID GID SIZE MODIFIED NAME],
                 rows.map { [_1.mode, _1.uid, _1.gid, _1.size, _1.mtime ? Time.parse(_1.mtime).localtime.strftime("%Y-%m-%d %H:%M") : "-",
                             _1.dir? ? "#{_1.name}/" : _1.name] })
    end

    def files_cat(args, o)
      raise Error, "cat takes one VOL:PATH" unless args.size == 1
      v, path = vol_ref!(args[0])
      $stdout.binmode.write(VolFS.read(read_image(v, o), path))
    end

    def files_cp(args, o)
      raise Error, "cp takes SRC and DST" unless args.size == 2
      src, dst = args.map { vol_ref(_1) }
      raise Error, "one side must be VOL:PATH (a volume of #{app.name})" if !src && !dst
      raise Error, "copy between volumes through a local dir (one side local)" if src && dst
      if src
        v, path = src
        img = read_image(v, o)
        if args[1].end_with?("/") && !File.directory?(args[1])
          raise Error, "#{args[1]}: no such directory"
        end
        local = File.directory?(args[1]) ? File.join(args[1], path == "/" ? v["name"] : File.basename(path)) : args[1]
        raise Error, "#{File.dirname(File.expand_path(local))}: no such directory" unless File.directory?(File.dirname(File.expand_path(local)))
        VolFS.export(img, path, local)
        puts "Copied #{v['name']}:#{path} to #{local}"
      else
        raise Error, "--backup is for copying out of a backup" if o[:backup]
        local = File.expand_path(args[0])
        raise Error, "#{args[0]} doesn't exist" unless File.exist?(local) || File.symlink?(local)
        v, path = dst
        write_volume(v) do |img|
          e = VolFS.stat(img, path)
          target = e&.dir? ? File.join(path, File.basename(local)) : path
          parent = VolFS.stat!(img, File.dirname(target))
          raise Error, "#{File.dirname(target)} isn't a directory" unless parent.dir?
          uid, gid = o[:owner] ? owner_opt(o[:owner]) : [parent.uid, parent.gid]
          gid ||= uid
          cmds = []
          if (t = VolFS.stat(img, target))
            raise Error, "#{target} is a directory in the volume; rm -r it first to replace it" if t.dir?
            raise Error, "#{target} exists in the volume and #{args[0]} is a directory" if File.directory?(local)
            cmds << "rm #{VolFS.q(target)}"
          end
          puts "==> #{args[0]} -> #{v['name']}:#{target} (owner #{uid}:#{gid})"
          cmds + VolFS.import_cmds(local, target, uid, gid)
        end
        puts "Copied into #{v['name']}"
        next_step(v["attached_machine"] ? "flk machine start #{v['attached_machine']}" : "flk files ls #{v['name']}:#{File.dirname(path)}")
      end
    end

    def files_rm(args, o)
      raise Error, "rm takes one VOL:PATH" unless args.size == 1
      v, path = vol_ref!(args[0])
      raise Error, "won't delete / of a volume (destroy the volume instead)" if path == "/"
      write_volume(v) { |img| VolFS.remove_cmds(img, path, recursive: o[:recursive]) }
      puts "Deleted #{v['name']}:#{path}"
    end

    def files_mkdir(args, o)
      raise Error, "mkdir takes one VOL:PATH" unless args.size == 1
      v, path = vol_ref!(args[0])
      write_volume(v) do |img|
        if (e = VolFS.stat(img, path))
          raise Error, "#{path} exists" unless o[:parents] && e.dir?
          next []
        end
        missing = []
        p = path
        until (parent = VolFS.stat(img, p))
          missing.unshift(p)
          p = File.dirname(p)
        end
        raise Error, "#{p} isn't a directory" unless parent.dir?
        raise Error, "#{File.dirname(path)} doesn't exist (use -p)" if missing.size > 1 && !o[:parents]
        uid, gid = o[:owner] ? owner_opt(o[:owner]) : [parent.uid, parent.gid]
        gid ||= uid
        missing.flat_map { ["mkdir #{VolFS.q(_1)}", *VolFS.owner_cmds(_1, uid, gid)] }
      end
      puts "Made #{v['name']}:#{path}"
    end

    def files_chown(args, o)
      raise Error, "chown takes UID[:GID] and VOL:PATH" unless args.size == 2
      uid, gid = owner_opt(args[0])
      v, path = vol_ref!(args[1])
      write_volume(v) { |img| VolFS.chown_cmds(img, path, uid, gid, recursive: o[:recursive]) }
      puts "Changed the owner of #{v['name']}:#{path}#{' and everything under it' if o[:recursive]} to #{uid}#{":#{gid}" if gid}"
    end
  end
end
