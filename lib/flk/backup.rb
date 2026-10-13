module Flk
  # Volume backups: whole-image copies of a volume's ext4 file, kept as
  # DIR/APP/VOLUME/VOLUME-YYYYmmddTHHMMSSZ.ext4 plus a .json beside it.
  # Copies are sparse (only used blocks take space) and reflinked when DIR
  # is on the same reflink-capable filesystem (XFS, btrfs): then instant.
  # How the machine is kept from writing during the copy is the caller's
  # job (CLI#volumes_backup and [flk.backup] in flk.toml).
  module Backup
    STAMP = "%Y%m%dT%H%M%SZ"
    NAME_RE = /\A(?<vol>[a-z0-9_]+)-(?<stamp>\d{8}T\d{6}Z)\.ext4\z/
    DEFAULT_KEEP = 7

    module_function

    # Where backups go: --to, else backup_dir in the host settings.
    def root!(to)
      dir = to || Host.settings["backup_dir"]
      unless dir
        raise Error, "no backup destination: pass --to DIR, or set backup_dir in #{Host::PATH} " \
                     "(e.g. backup_dir = \"/data/flk-backups\")"
      end
      dir = File.expand_path(dir)
      raise Error, "backup dir #{dir} doesn't exist (is its disk mounted?)" unless File.directory?(dir)
      raise Error, "backup dir #{dir} isn't writable by you" unless File.writable?(dir)
      dir
    end

    def keep(opt) = Integer(opt || Host.settings["backup_keep"] || DEFAULT_KEEP)

    def dir_for(root, app, vol) = File.join(root, app, vol["name"])

    # Newest first: [{ "file", "path", "created_at", ...meta }]
    def list(root, app, vol)
      d = dir_for(root, app, vol)
      return [] unless File.directory?(d)
      Dir.children(d).filter_map do |f|
        md = NAME_RE.match(f) or next
        next unless md[:vol] == vol["name"]
        path = File.join(d, f)
        meta = (JSON.parse(File.read(path.sub(/\.ext4\z/, ".json"))) rescue {})
        meta.merge("file" => f, "path" => path, "created_at" => meta["created_at"] || stamp_iso(md[:stamp]),
                   "bytes_used" => File.stat(path).blocks * 512)
      end.sort_by { _1["file"] }.reverse
    end

    def stamp_iso(s) = Time.strptime(s, STAMP).utc.iso8601

    # A named backup ("latest", a file name, or its time stamp).
    def find!(root, app, vol, ref)
      all = list(root, app, vol)
      raise Error, "no backups of #{app}/#{vol['name']} in #{dir_for(root, app, vol)}" if all.empty?
      return all.first if ref.nil? || ref == "latest"
      all.find { _1["file"] == ref || _1["file"].include?(ref) } ||
        raise(Error, "no backup '#{ref}' of #{vol['name']}; see: flk volumes backups #{vol['name']}")
    end

    # Bytes the copy of src will take (its allocated blocks, not its size).
    def used_bytes(src) = File.stat(src).blocks * 512

    def free_bytes(dir)
      Util.run!("df", "--output=avail", "-B1", dir).lines.last.to_i
    end

    def same_fs?(a, b) = File.stat(a).dev == File.stat(b).dev

    def room!(src, dir)
      need = used_bytes(src)
      free = free_bytes(dir)
      return if free > need * 1.05 + 1024**3
      raise Error, "not enough space in #{dir}: the copy needs about #{gb(need)}, #{gb(free)} is free"
    end

    # Sparse (and reflinked when possible) copy to a .partial file, renamed
    # into place only when complete, so a crash never leaves a half backup.
    def copy(src, dst)
      part = "#{dst}.partial"
      FileUtils.rm_f(part)
      Util.run!("cp", "--sparse=always", "--reflink=auto", src, part)
      File.rename(part, dst)
    ensure
      FileUtils.rm_f(part) if part && File.exist?(part)
    end

    # e2fsck on the copy (never on the live volume). -y: a copy taken while
    # the machine ran is like a disk after a power cut, so replaying its
    # journal here is expected. Returns "clean", "repaired" or "errors".
    def check(path)
      bin = Util.which("e2fsck") || %w[/usr/sbin/e2fsck /sbin/e2fsck].find { File.executable?(_1) } or return "unchecked"
      _out, st = Open3.capture2e(bin, "-fy", path)
      case st.exitstatus
      when 0 then "clean"
      when 1, 2 then "repaired"
      else "errors"
      end
    end

    def write_meta(path, meta) = Util.write_json(path.sub(/\.ext4\z/, ".json"), meta)

    # Deletes all but the newest `keep` backups; returns the deleted files.
    def prune(root, app, vol, keep)
      list(root, app, vol).drop(keep).each do |b|
        FileUtils.rm_f([b["path"], b["path"].sub(/\.ext4\z/, ".json")])
      end.map { _1["file"] }
    end

    def gb(bytes) = "#{(bytes / 1024.0**3).round(1)}GB"
  end
end
