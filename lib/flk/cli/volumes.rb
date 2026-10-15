module Flk
  # flk volumes list, create, import, move, extend, destroy
  class CLI
    private

    def volumes_list(_args, o)
      v = app.volumes
      return puts(JSON.pretty_generate(v)) if o[:json]
      return puts("No volumes") if v.empty?
      ext = v.any? { App.external_volume?(_1) }
      Util.table(%w[ID NAME SIZE ATTACHED CREATED] + (ext ? ["FILE (external)"] : []),
                 v.map { [_1["id"], _1["name"], "#{_1['size_gb']}GB", _1["attached_machine"] || "-", Util.ago(_1["created_at"])] +
                         (ext ? [App.external_volume?(_1) ? _1["path"] : "-"] : []) })
    end

    def volume_name!(name)
      raise Error, "volume names: lowercase letters, digits, underscores" unless name.match?(/\A[a-z0-9_]{1,30}\z/)
      name
    end

    # An image file outside flk's state dir: flk never deletes it. Refuses a
    # file another volume (in any app) already uses.
    def external_path!(path)
      full = File.expand_path(path)
      raise Error, "#{full} is inside flk's state dir; leave out --path for that" if full.start_with?("#{ROOT}/")
      App.all.each do |other|
        if (v = other.volumes.find { _1["path"] == full })
          raise Error, "#{full} is already volume #{v['id']} (#{v['name']}) of app #{other.name}"
        end
      end
      full
    end

    def register_volume(a, h)
      Util.with_lock do
        vols = a.volumes
        vols << h.merge("attached_machine" => nil, "created_at" => Util.now)
        a.save_volumes(vols)
      end
    end

    def volumes_create(args, o)
      a = app
      name = volume_name!(args.first)
      size = o[:size] || 1
      raise Error, "--size must be at least 1 (GB)" if size < 1
      id = "vol_#{SecureRandom.hex(8)}"
      path = o[:path] ? external_path!(o[:path]) : File.join(a.dir, "volumes", "#{id}.ext4")
      if o[:path]
        raise Error, "#{path} already exists; to use an existing image: flk volumes import #{name} --path #{path}" if File.exist?(path)
        raise Error, "#{File.dirname(path)} doesn't exist" unless File.directory?(File.dirname(path))
      end
      from = o[:from_dir] && from_dir!(o[:from_dir], size)
      FileUtils.mkdir_p(File.dirname(path))
      puts "==> Copying #{from} into the volume (this can take a while)" if from
      Util.mkfs_ext4(path, size * 1024, label: name, from_dir: from)
      register_volume(a, { "id" => id, "name" => name, "size_gb" => size, "path" => path }.merge(o[:path] ? { "external" => true } : {}))
      puts "Created #{id} (#{name}, #{size}GB sparse#{", at #{path}" if o[:path]}#{", from #{from}" if from})"
      puts "Note: files keep their owner/group IDs from #{from}; the app may need to run as that user (or chown inside)." if from
      boot_unit_note(path) if o[:path]
      next_step("[[mounts]] source = \"#{name}\" in flk.toml, then flk deploy")
    end

    # A volume on another disk: the boot service must wait for that mount
    # (usually it already does; see mount_gap).
    def boot_unit_note(path)
      return unless File.exist?("/etc/systemd/system/flk-machines.service")
      problem, how = mount_gap(File.dirname(path))
      puts Util.yellow("#{problem}\n  -> #{how}") if problem
    end

    # --from-dir must fit with headroom: ext4 metadata takes a few percent.
    def from_dir!(dir, size_gb)
      full = File.expand_path(dir)
      raise Error, "#{full} isn't a directory" unless File.directory?(full)
      used = Util.run!("du", "-sb", full).split.first.to_i
      cap = size_gb * 1024**3
      if used > cap * 0.9
        raise Error, "#{full} holds #{(used / 1024.0**3).round(1)}GB, too much for a #{size_gb}GB volume; " \
                     "use --size #{(used * 1.25 / 1024**3).ceil}"
      end
      full
    end

    def volumes_import(args, o)
      a = app
      name = volume_name!(args.first)
      path = external_path!(o[:path] || raise(Error, "--path FILE is required"))
      raise Error, "#{path} doesn't exist" unless File.file?(path)
      raise Error, "#{path} isn't writable by you (machines open it read-write)" unless File.writable?(path)
      type = (Util.run!("blkid", "-o", "value", "-s", "TYPE", path).strip rescue "")
      raise Error, "#{path} isn't an ext4 image (blkid says '#{type.empty? ? 'unknown' : type}')" unless type == "ext4"
      id = "vol_#{SecureRandom.hex(8)}"
      size = (File.size(path) / 1024.0**3).ceil
      register_volume(a, { "id" => id, "name" => name, "size_gb" => size, "path" => path, "external" => true })
      puts "Imported #{path} as #{id} (#{name}, #{size}GB). flk won't delete this file."
      puts "Don't mount it on the host while a machine uses it."
      boot_unit_note(path)
      next_step("[[mounts]] source = \"#{name}\" in flk.toml, then flk deploy")
    end

    def volumes_move(args, o)
      a = app
      v = a.volume!(args.first)
      raise Error, "pass --dir DIR or --path FILE" unless o[:dir] || o[:path]
      raise Error, "--dir and --path don't go together" if o[:dir] && o[:path]
      if (m = volume_user(a, v))
        raise Error, "machine #{m.id} [#{m.name}] is using #{v['name']}; stop it first: flk machine stop #{m.id}"
      end
      src = v["path"]
      raise Error, "#{src} is missing (is its disk mounted?)" unless File.exist?(src)
      dst = File.expand_path(o[:path] || File.join(o[:dir], App.external_volume?(v) ? File.basename(src) : "#{a.name}-#{v['name']}-#{v['id']}.ext4"))
      raise Error, "#{v['name']} is already at #{dst}" if dst == src
      raise Error, "#{dst} already exists" if File.exist?(dst)
      raise Error, "#{File.dirname(dst)} doesn't exist" unless File.directory?(File.dirname(dst))
      internal = dst.start_with?("#{ROOT}/")
      external_path!(dst) unless internal # another volume's file?
      Backup.room!(src, File.dirname(dst))
      puts "==> Moving #{v['name']} (#{Backup.gb(Backup.used_bytes(src))} used) to #{dst}"
      t0 = Time.now
      Util.with_lock do
        raise Error, "#{v['name']} is in use again" if volume_user(a, v)
        begin
          Backup.copy(src, dst, idle: false)
          raise Error, "the copy at #{dst} isn't clean (e2fsck -n); the volume still uses #{src}" unless Backup.fsck_readonly(dst) == "clean"
        rescue StandardError
          FileUtils.rm_f(dst)
          raise
        end
        vols = a.volumes
        rec = vols.find { _1["id"] == v["id"] }
        rec["path"] = dst
        internal ? rec.delete("external") : rec["external"] = true
        a.save_volumes(vols)
      end
      old_kept = App.external_volume?(v)
      FileUtils.rm_f(src) unless old_kept
      puts "Moved #{v['name']} in #{(Time.now - t0).round(1)}s#{" (#{fs_type(dst)}#{', backups there are instant' if %w[xfs btrfs].include?(fs_type(dst))})" if fs_type(dst)}."
      puts old_kept ? "The old file is kept (flk doesn't delete external files): #{src}" : "Deleted the old file #{src}."
      boot_unit_note(dst) unless internal
      next_step(v["attached_machine"] ? "flk machine start #{v['attached_machine']}" : "flk deploy")
    end

    def fs_type(path)
      dir = File.directory?(path) ? path : File.dirname(path)
      out, st = Open3.capture2("findmnt", "-n", "-o", "FSTYPE", "--target", dir)
      out, st = Open3.capture2("stat", "-f", "-c", "%T", dir) unless st.success? && !out.strip.empty?
      st.success? ? out.strip : nil
    rescue SystemCallError
      nil
    end

    def volumes_extend(args, o)
      a = app
      v = a.volume!(args.first)
      size = o[:size] or raise Error, "--size GB is required"
      raise Error, "#{v['name']} is #{v['size_gb']}GB; volumes only grow (--size more than that)" unless size > v["size_gb"].to_i
      if (m = volume_user(a, v))
        raise Error, "machine #{m.id} [#{m.name}] is using #{v['name']}; stop it first: flk machine stop #{m.id}"
      end
      path = v["path"]
      Util.with_lock do
        fsck = Util.which("e2fsck") || "/usr/sbin/e2fsck"
        out, st = Open3.capture2e(fsck, "-fy", path)
        raise Error, "e2fsck found errors it couldn't fix in #{path}:\n#{out}" if st.exitstatus.to_i > 2
        File.open(path, "r+") { _1.truncate(size * 1024**3) } # sparse: takes no space until used
        Util.run!(Util.which("resize2fs") || "/usr/sbin/resize2fs", path)
        set_volume_size(a, v, path)
      end
      puts "Extended #{v['name']} to #{size}GB"
      next_step(v["attached_machine"] ? "flk machine start #{v['attached_machine']}" : "flk deploy")
    end

    def set_volume_size(a, v, path)
      vols = a.volumes
      vols.find { _1["id"] == v["id"] }["size_gb"] = (File.size(path) / 1024.0**3).ceil
      a.save_volumes(vols)
    end

    # External volumes (--path / import) are only unregistered unless
    # --delete-data: flk didn't create that file, so it won't silently delete it.
    def volumes_destroy(args, o)
      a = app
      ref = args.first
      Util.with_lock do
        v = a.volume!(ref)
        if v["attached_machine"]
          raise Error, "#{v['id']} is attached to machine #{v['attached_machine']}; destroy that machine first"
        end
        keep = App.external_volume?(v) && !o[:delete_data]
        FileUtils.rm_f(v["path"]) unless keep
        a.save_volumes(a.volumes.reject { _1["id"] == v["id"] })
        puts keep ? "Unregistered #{v['id']}; file kept at #{v['path']} (--delete-data deletes it)" : "Destroyed #{v['id']}"
      end
    end
  end
end
