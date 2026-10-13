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

    # Copy to a .partial file, renamed into place only when complete, so a
    # crash never leaves a half backup. A reflink when the filesystem can
    # (XFS, btrfs: instant, no I/O). Else a sparse copy that keeps out of the
    # host's way: at idle I/O priority (idle: false when the machine is
    # stopped or paused for it, to keep that short), synced and dropped from
    # the page cache as it goes, so a 20G volume doesn't evict everything
    # else cached (and push the game VMs' memory towards swap).
    def copy(src, dst, idle: true)
      part = "#{dst}.partial"
      FileUtils.rm_f(part)
      unless system("cp", "--reflink=always", src, part, out: File::NULL, err: File::NULL)
        FileUtils.rm_f(part)
        pid = fork do
          system("ionice", "-c3", "-p", Process.pid.to_s, out: File::NULL, err: File::NULL) if idle
          stream_copy(src, part)
          exit!(0)
        rescue Exception => e # rubocop:disable Lint/RescueException -- report anything, then leave
          warn "flk: copying #{src}: #{e.message}"
          exit!(1)
        end
        Process.wait(pid)
        raise Error, "copying #{src} to #{part} failed" unless $?.success?
      end
      File.rename(part, dst)
    ensure
      FileUtils.rm_f(part) if part && File.exist?(part)
    end

    CHUNK = 1 << 20     # all-zero chunks stay holes, like cp --sparse=always
    DROP_EVERY = 64 << 20

    # Data extents only (SEEK_DATA/SEEK_HOLE), so holes stay holes; every
    # DROP_EVERY bytes the copy is synced and both files' pages are
    # dropped from the page cache (posix_fadvise DONTNEED).
    def stream_copy(src, dst)
      File.open(src, "rb") do |i|
        File.open(dst, File::WRONLY | File::CREAT | File::TRUNC, File.stat(src).mode & 0o777) do |o|
          size = i.size
          o.truncate(size)
          pos = 0
          dropped = 0
          drop = lambda do |upto|
            o.fdatasync
            [i, o].each { _1.advise(:dontneed, dropped, upto - dropped) }
            dropped = upto
          end
          while pos < size
            begin
              i.seek(pos, IO::SEEK_DATA)
            rescue Errno::ENXIO # no data after pos
              break
            end
            off = i.pos
            i.seek(off, IO::SEEK_HOLE)
            hole = i.pos
            while off < hole
              buf = i.pread([CHUNK, hole - off].min, off)
              o.pwrite(buf, off) unless buf.count("\0") == buf.bytesize
              off += buf.bytesize
              drop.call(off) if off - dropped >= DROP_EVERY
            end
            pos = hole
          end
          drop.call(size)
        end
      end
    end

    # After e2fsck read (and maybe wrote) the copy: out of the page cache.
    def drop_cache(path)
      File.open(path, "r+") do |f|
        f.fdatasync
        f.advise(:dontneed, 0, 0)
      end
    rescue SystemCallError
      nil
    end

    # e2fsck on the copy (never on the live volume). A copy taken while the
    # machine ran is like a disk after a power cut: its journal needs
    # replaying, which is normal, so that's done first and doesn't count.
    # Then a full check: "clean", or "repaired"/"errors" with e2fsck's
    # output kept in BACKUP.fsck.log. Returns [state, journal_replayed].
    def check(path)
      bin = Util.which("e2fsck") || %w[/usr/sbin/e2fsck /sbin/e2fsck].find { File.executable?(_1) }
      return ["unchecked", false] unless bin
      replayed = needs_recovery?(path)
      Open3.capture2e(bin, "-y", "-E", "journal_only", path) if replayed
      out, st = Open3.capture2e(bin, "-fy", path)
      state = case st.exitstatus
              when 0 then "clean"
              when 1, 2 then out.scan(/\? yes/).size > out.scan(UNJOURNALED).size ? "repaired" : "clean"
              else "errors"
              end
      File.write(path.sub(/\.ext4\z/, ".fsck.log"), out) unless state == "clean"
      drop_cache(path)
      [state, replayed]
    end

    # The superblock's free block/inode totals aren't journaled: a running
    # ext4 keeps them in memory, so any copy of one has them off. Fixing
    # them is part of a normal recovery, not a repair.
    UNJOURNALED = /^Free (?:blocks|inodes) count wrong \(\d+, counted=\d+\)\./

    def needs_recovery?(path)
      bin = Util.which("dumpe2fs") || %w[/usr/sbin/dumpe2fs /sbin/dumpe2fs].find { File.executable?(_1) } or return false
      out, _ = Open3.capture2e(bin, "-h", path)
      out.match?(/^Filesystem features:.*needs_recovery/)
    end

    def write_meta(path, meta) = Util.write_json(path.sub(/\.ext4\z/, ".json"), meta)

    # Deletes all but the newest `keep` backups; returns the deleted files.
    def prune(root, app, vol, keep)
      list(root, app, vol).drop(keep).each do |b|
        FileUtils.rm_f(%w[.ext4 .json .fsck.log].map { b["path"].sub(/\.ext4\z/, _1) })
      end.map { _1["file"] }
    end

    def gb(bytes) = "#{(bytes / 1024.0**3).round(1)}GB"
  end
end
