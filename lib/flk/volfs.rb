require "tempfile"

module Flk
  # Files inside a volume's ext4 image, without mounting it (no root): on
  # top of debugfs. Reads work on any image (a volume, a backup); writes
  # need the image unused (the caller checks that no machine runs on it).
  # Paths are absolute inside the image.
  module VolFS
    Entry = Struct.new(:name, :type, :size, :uid, :gid, :mode, :mtime) do
      def dir? = type == "dir"
      def to_h = super.transform_keys(&:to_s)
    end

    TYPES = { 0o040000 => "dir", 0o100000 => "file", 0o120000 => "symlink" }.freeze

    module_function

    def bin
      Util.which("debugfs") || %w[/usr/sbin/debugfs /sbin/debugfs].find { File.executable?(_1) } ||
        raise(Error, "debugfs not found (install e2fsprogs)")
    end

    # "/a/b/" -> "/a/b"; refuses what debugfs can't quote.
    def clean(path)
      p = File.expand_path(path.to_s.empty? ? "/" : path, "/")
      raise Error, "paths with \" or newlines aren't supported: #{path.inspect}" if p.match?(/["\n]/)
      p
    end

    def q(path) = "\"#{clean(path)}\""

    def run_r(img, cmd)
      out, _err, st = Open3.capture3({ "TZ" => "UTC" }, bin, "-R", cmd, img)
      raise Error, "debugfs failed on #{img}" unless st.success?
      out
    end

    # nil when path doesn't exist, else an Entry.
    def stat(img, path)
      p = clean(path)
      out, err, = Open3.capture3({ "TZ" => "UTC" }, bin, "-R", "stat #{q(p)}", img)
      return nil if out.empty? || err.include?("File not found")
      mode = out[/Mode:\s+(\d+)/, 1].to_i(8)
      type = out[/Type:\s+(\w+)/, 1]
      type = { "regular" => "file", "directory" => "dir", "symlink" => "symlink" }[type] || type
      Entry.new(p == "/" ? "/" : File.basename(p), type, out[/Size:\s+(\d+)/, 1].to_i,
                out[/User:\s+(\d+)/, 1].to_i, out[/Group:\s+(\d+)/, 1].to_i, format("%04o", mode & 0o7777),
                (Time.at(out[/^\s*mtime: 0x(\h+)/, 1].to_i(16)).utc.iso8601 rescue nil))
    end

    def stat!(img, path) = stat(img, path) || raise(Error, "#{clean(path)}: no such file or directory in the volume")

    LS_RE = /\A\s*\d+\s+(\d+)\s+\(\d+\)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+-\w{3}-\d{4} \d\d:\d\d) (.*)\z/

    # A directory's entries (no . and ..), sorted by name.
    def list(img, dir)
      e = stat!(img, dir)
      return [e.tap { _1.name = File.basename(clean(dir)) }] unless e.dir?
      run_r(img, "ls -l #{q(dir)}").lines.filter_map do |l|
        md = LS_RE.match(l.chomp) or next
        next if %w[. ..].include?(md[6])
        mode = md[1].to_i(8)
        Entry.new(md[6], TYPES[mode & 0o170000] || "other", md[4].to_i, md[2].to_i, md[3].to_i,
                  format("%04o", mode & 0o7777), (Time.strptime("#{md[5]} UTC", "%d-%b-%Y %H:%M %Z").utc.iso8601 rescue nil))
      end.sort_by(&:name)
    end

    # File contents (binary).
    def read(img, path)
      e = stat!(img, path)
      raise Error, "#{clean(path)} is a #{e.type}, not a file" unless e.type == "file"
      out, _err, st = Open3.capture3(bin, "-R", "cat #{q(path)}", img, binmode: true)
      raise Error, "debugfs failed reading #{clean(path)}" unless st.success?
      out
    end

    # Copies path out of the image to local (a file, or a directory tree).
    def export(img, path, local)
      e = stat!(img, path)
      if e.dir?
        FileUtils.mkdir_p(local)
        # rdump DIR DEST makes DEST/basename(DIR)
        Dir.mktmpdir("flk-export", File.dirname(File.expand_path(local))) do |t|
          run_r(img, "rdump #{q(path)} \"#{t}\"")
          src = File.join(t, clean(path) == "/" ? "" : File.basename(clean(path)))
          src = t if clean(path) == "/"
          Dir.children(src).each { FileUtils.mv(File.join(src, _1), local) }
        end
      else
        File.binwrite(local, read(img, path))
      end
    end

    # Runs write commands; any output besides the echo and "Allocated
    # inode" is an error. Commands are [cmd, args...] with paths quoted.
    def batch!(img, cmds)
      return if cmds.empty?
      Tempfile.create("flk-debugfs") do |f|
        f.puts(cmds)
        f.flush
        out, err, st = Open3.capture3(bin, "-w", "-f", f.path, img)
        bad = (out + err).lines.map(&:chomp).reject do |l|
          l.empty? || l.start_with?("debugfs ") || l.start_with?("debugfs: ") || l.match?(/\AAllocated inode: \d+\z/)
        end
        raise Error, "debugfs: #{bad.first(5).join('; ')}" if bad.any? || !st.success?
      end
    end

    def owner_cmds(path, uid, gid) = ["sif #{q(path)} uid #{uid}", "sif #{q(path)} gid #{gid}"]

    # Commands that copy local (file, symlink or directory tree) to dest
    # (a path that doesn't exist yet), owned by uid:gid.
    def import_cmds(local, dest, uid, gid)
      st = File.lstat(local)
      if st.symlink?
        ["symlink #{q(dest)} \"#{File.readlink(local).tap { clean(_1) }}\"", *owner_cmds(dest, uid, gid)]
      elsif st.directory?
        ["mkdir #{q(dest)}", "sif #{q(dest)} mode 0#{format('%o', 0o040000 | (st.mode & 0o7777))}", *owner_cmds(dest, uid, gid)] +
          Dir.children(local).sort.flat_map { import_cmds(File.join(local, _1), File.join(dest, _1), uid, gid) }
      elsif st.file?
        raise Error, "#{local}: names with \" aren't supported" if local.include?('"')
        ["write \"#{local}\" #{q(dest)}", *owner_cmds(dest, uid, gid)]
      else
        raise Error, "#{local}: only files, directories and symlinks can be copied"
      end
    end

    # Commands that delete path (a tree with recursive).
    def remove_cmds(img, path, recursive:)
      e = stat!(img, path)
      return ["rm #{q(path)}"] unless e.dir?
      kids = list(img, path)
      raise Error, "#{clean(path)} is a directory that isn't empty (use -r)" if kids.any? && !recursive
      kids.flat_map { remove_cmds(img, File.join(clean(path), _1.name), recursive: true) } + ["rmdir #{q(path)}"]
    end

    def chown_cmds(img, path, uid, gid, recursive:)
      e = stat!(img, path)
      own = owner_cmds(path, uid || e.uid, gid || e.gid)
      return own unless recursive && e.dir?
      own + list(img, path).flat_map { chown_cmds(img, File.join(clean(path), _1.name), uid, gid, recursive: true) }
    end

    # e2fsck -fy after writes; raises unless clean or fixed.
    def fsck!(img)
      fsck = Util.which("e2fsck") || "/usr/sbin/e2fsck"
      out, st = Open3.capture2e(fsck, "-fy", img)
      raise Error, "e2fsck found errors it couldn't fix in #{img}:\n#{out}" if st.exitstatus.to_i > 2
      st.exitstatus.to_i.zero? ? "clean" : "repaired"
    end
  end
end
