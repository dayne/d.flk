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

    def room?(need, free) = free > need * 1.05 + 1024**3

    def room!(src, dir)
      need = used_bytes(src)
      free = free_bytes(dir)
      return if room?(need, free)
      raise Error, "not enough space in #{dir}: the copy needs about #{gb(need)}, #{gb(free)} is free"
    end

    # Space for a new backup of src, before copying. When it doesn't fit
    # but would once the backups this one pushes past `keep` are gone,
    # those go first (only with keep >= 2, so one older backup always
    # stays). Returns { pruned: [files], steady:, available: } where
    # steady is roughly what `keep` backups of this volume will take and
    # available what they can have (free space plus the existing ones).
    def make_room!(src, root, app, vol, keep)
      dir = dir_for(root, app, vol)
      need = used_bytes(src)
      have = list(root, app, vol)
      free = free_bytes(dir)
      pruned = []
      unless room?(need, free)
        going = have.drop(keep - 1)
        if keep >= 2 && going.any? && room?(need, free + going.sum { _1["bytes_used"] })
          pruned = prune(root, app, vol, keep - 1)
          free = free_bytes(dir)
        else
          raise Error, "not enough space in #{dir}: the copy needs about #{gb(need)}, #{gb(free)} is free" \
                       "#{" (#{have.size} older backups there take #{gb(have.sum { _1['bytes_used'] })}; fewer with --keep)" if have.any?}"
        end
      end
      { pruned: pruned, steady: need * keep, available: free + list(root, app, vol).sum { _1["bytes_used"] } }
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

    # Puts a backup's data back into dst in place (dst's machine stopped):
    # no second copy of a big volume needs room beside it. The backup
    # stays, so a cut-off restore can simply be run again.
    def restore_over(src, dst)
      return if system("cp", "--reflink=always", src, dst, out: File::NULL, err: File::NULL)
      pid = fork do
        stream_copy(src, dst)
        exit!(0)
      rescue Exception => e # rubocop:disable Lint/RescueException -- report anything, then leave
        warn "flk: restoring #{dst}: #{e.message}"
        exit!(1)
      end
      Process.wait(pid)
      raise Error, "restoring #{dst} from #{src} failed (run it again: the backup is still there)" unless $?.success?
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

    def update_meta(path, h)
      json = path.sub(/\.ext4\z/, ".json")
      Util.write_json(json, (JSON.parse(File.read(json)) rescue {}).merge(h))
    end

    # Checks a backup without changing it: e2fsck -n (read only), then the
    # [flk.backup] verify hook (a host command, run in hook_dir with
    # FLK_BACKUP = the image, FLK_APP, FLK_VOLUME) that can look inside it,
    # e.g. with debugfs. A copy taken with --no-check still needs its
    # journal replayed, so it gets the full check that backup skipped.
    # Records { verify: clean|errors|hook_failed, verified_at, verify_detail }
    # in the backup's .json and returns that.
    def verify(b, hook:, hook_dir:, env:)
      path = b["path"]
      detail = nil
      state = if b["check"].nil? || b["check"] == "unchecked" || needs_recovery?(path)
                st, = check(path)
                update_meta(path, "check" => st)
                detail = "e2fsck: #{st} (first check of this copy)"
                st == "errors" ? "errors" : "clean"
              else
                fsck_readonly(path).tap { detail = "e2fsck -n: #{_1}" }
              end
      if state == "clean" && hook
        ok, out = run_hook(hook, hook_dir, env.merge("FLK_BACKUP" => path))
        tail = out.lines.last(20).join.strip
        detail = [detail, "verify hook: #{ok ? 'passed' : 'failed'}#{": #{tail}" unless tail.empty?}"].join("; ")
        state = "hook_failed" unless ok
      end
      res = { "verify" => state, "verified_at" => Util.now, "verify_detail" => detail }
      update_meta(path, res)
      res
    end

    def fsck_readonly(path)
      bin = Util.which("e2fsck") || %w[/usr/sbin/e2fsck /sbin/e2fsck].find { File.executable?(_1) }
      return "unchecked" unless bin
      out, st = Open3.capture2e(bin, "-fn", path)
      File.write(path.sub(/\.ext4\z/, ".verify.log"), out) unless st.success?
      drop_cache(path)
      st.success? ? "clean" : "errors"
    end

    HOOK_TIMEOUT = 600

    # [ok, combined output]
    def run_hook(cmd, dir, env)
      out = +""
      Open3.popen2e(env, "sh", "-c", cmd, chdir: dir, in: File::NULL) do |_i, oe, th|
        reader = Thread.new { oe.each_line { out << _1 } }
        unless Util.wait_for(HOOK_TIMEOUT, 0.1) { !th.alive? }
          VM.kill(th.pid, "KILL")
          reader.join(1)
          return [false, "#{out}timed out after #{HOOK_TIMEOUT}s"]
        end
        reader.join
        [th.value.success?, out]
      end
    end

    # Deletes all but the newest `keep` backups; returns the deleted files.
    def prune(root, app, vol, keep)
      list(root, app, vol).drop(keep).each do |b|
        FileUtils.rm_f(%w[.ext4 .json .fsck.log .verify.log].map { b["path"].sub(/\.ext4\z/, _1) })
      end.map { _1["file"] }
    end

    def gb(bytes) = "#{(bytes / 1024.0**3).round(1)}GB"

    # ---------- copies elsewhere (host backup_copy_to) ----------
    # A copy target is a local dir (another disk) or HOST:DIR / USER@HOST:DIR
    # (rsync over ssh, keys only). Copies are laid out like backup_dir:
    # DEST/APP/VOLUME/FILE.ext4 + .json.

    def remote?(dest) = dest.match?(%r{\A[^/:]+:})

    def copy_dest!(dest)
      raise Error, "no copy destination: pass --dest, or set backup_copy_to in #{Host::PATH}" unless dest
      return dest if remote?(dest)
      dir = File.expand_path(dest)
      raise Error, "copy destination #{dir} doesn't exist (is its disk mounted?)" unless File.directory?(dir)
      raise Error, "copy destination #{dir} isn't writable by you" unless File.writable?(dir)
      dir
    end

    def copy_keep(opt) = Integer(opt || Host.settings["backup_copy_keep"] || Host.settings["backup_keep"] || DEFAULT_KEEP)

    RSYNC_SSH = "ssh -o BatchMode=yes -o ConnectTimeout=20"

    # Backup file names at dest/app/vol: { name => bytes }.
    def copies_at(dest, app, vol)
      if remote?(dest)
        out, st = Open3.capture2e("rsync", "--list-only", "-e", RSYNC_SSH, "#{dest}/#{app}/#{vol}/")
        return {} if !st.success? && out.include?("No such file or directory")
        raise Error, "listing #{dest}/#{app}/#{vol}: #{out.lines.last(3).join.strip}" unless st.success?
        out.lines.filter_map do |l|
          f = l.split.last
          [f, l.split[1].delete(",").to_i] if f&.match?(NAME_RE)
        end.to_h
      else
        d = File.join(dest, app, vol)
        return {} unless File.directory?(d)
        Dir.children(d).grep(NAME_RE).to_h { [_1, File.size(File.join(d, _1))] }
      end
    end

    # Sends backup b of app/vol to dest (unless it's there already), then
    # keeps the newest `keep` there. Records the result in b's .json
    # ("copies": one entry per destination) and returns that entry.
    def send_copy(b, dest, app, vol, keep:)
      t0 = Time.now
      entry = { "to" => dest, "at" => nil, "ok" => false }
      begin
        have = copies_at(dest, app, vol)
        if have[b["file"]] == File.size(b["path"])
          entry["already"] = true
        elsif remote?(dest)
          rsync!(dest, app, vol, [b["path"], b["path"].sub(/\.ext4\z/, ".json")])
        else
          d = File.join(dest, app, vol)
          FileUtils.mkdir_p(d)
          room!(b["path"], d)
          copy(b["path"], File.join(d, b["file"]))
          FileUtils.cp(b["path"].sub(/\.ext4\z/, ".json"), File.join(d, b["file"].sub(/\.ext4\z/, ".json")))
        end
        entry.merge!("ok" => true, "pruned" => prune_copies(dest, app, vol, keep))
      rescue Error, SystemCallError => e
        entry["error"] = e.message
      end
      entry.merge!("at" => Util.now, "seconds" => (Time.now - t0).round(1))
      old = (JSON.parse(File.read(b["path"].sub(/\.ext4\z/, ".json"))) rescue {})["copies"] || []
      update_meta(b["path"], "copies" => old.reject { _1["to"] == dest } + [entry.except("pruned", "already")])
      entry
    end

    # rsync at idle I/O priority, resumable (--partial-dir: a cut-off copy
    # never shows up as a backup), then out of the page cache.
    def rsync!(dest, app, vol, files)
      cmd = ["rsync", "-t", "--sparse", "--mkpath", "--partial-dir=.rsync-partial", "-e", RSYNC_SSH, *files, "#{dest}/#{app}/#{vol}/"]
      cmd = ["ionice", "-c3", *cmd] if Util.which("ionice")
      out, st = Open3.capture2e(*cmd)
      files.each { drop_cache(_1) }
      raise Error, "rsync to #{dest} failed: #{out.lines.last(3).join.strip}" unless st.success?
    end

    # Deletes all but the newest `keep` backups at dest; returns their names.
    def prune_copies(dest, app, vol, keep)
      old = copies_at(dest, app, vol).keys.sort.reverse.drop(keep)
      return [] if old.empty?
      names = old.flat_map { |f| %w[.ext4 .json .fsck.log .verify.log].map { f.sub(/\.ext4\z/, _1) } }
      if remote?(dest)
        # rsync from an empty dir, deleting only these names
        Dir.mktmpdir do |empty|
          inc = names.flat_map { ["--include", "/#{_1}"] }
          out, st = Open3.capture2e("rsync", "-r", "--delete", *inc, "--exclude", "*", "-e", RSYNC_SSH,
                                    "#{empty}/", "#{dest}/#{app}/#{vol}/")
          raise Error, "pruning #{dest}/#{app}/#{vol}: #{out.lines.last(3).join.strip}" unless st.success?
        end
      else
        FileUtils.rm_f(names.map { File.join(dest, app, vol, _1) })
      end
      old
    end

    # The newest successful copy to dest of any of these backups: time or nil.
    def newest_copy(backups, dest)
      backups.flat_map { Array(_1["copies"]) }.select { _1["ok"] && _1["to"] == dest }.map { Time.parse(_1["at"]) }.max
    end
  end
end
