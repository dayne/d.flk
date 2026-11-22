require "digest"

module Flk
  # Which guest kernel a machine booted. One kernel serves the host
  # (VM.kernel: STATE/kernel/vmlinux, or FLK_KERNEL), and `flk setup`
  # replaces it; every machine boots the new one at its next start. So
  # each boot and each release record what they got: its version and the
  # file's sha256 (two builds of one version differ in config).
  module Kernel
    module_function

    def cache_path = File.join(ROOT, "kernel-info.json")

    # { "version" => "6.18.56" or nil, "sha256" => hex } for the kernel at
    # path, nil when there is none. Hashing 30MB takes a moment, so it is
    # kept per path until the file's size or mtime changes.
    def info(path = VM.kernel)
      st = File.stat(path)
      key = { "size" => st.size, "mtime" => st.mtime.to_f.round(6) }
      cache = Util.read_json(cache_path, {})
      hit = cache[path]
      return hit.slice("version", "sha256") if hit.is_a?(Hash) && hit.slice("size", "mtime") == key && hit["sha256"]
      found = { "version" => version(path), "sha256" => Digest::SHA256.file(path).hexdigest }
      begin
        Util.write_json(cache_path, cache.merge(path => key.merge(found)))
      rescue SystemCallError
        nil # a state dir that can't be written: hash it again next time
      end
      found
    rescue SystemCallError
      nil
    end

    # What `uname -r` says in the guest: from the banner inside the image
    # ("Linux version 6.18.56+ (..."), else from the build config flk
    # setup keeps next to it ("# Linux/x86 6.18.56 Kernel Configuration").
    def version(path)
      banner(path) || begin
        cfg = "#{path}.config"
        File.file?(cfg) ? File.foreach(cfg).first(5).join[%r{^# Linux/\S+ (\S+) Kernel Configuration}, 1] : nil
      end
    rescue SystemCallError
      nil
    end

    def banner(path)
      File.open(path, "rb") do |f|
        tail = "".b
        while (buf = f.read(1 << 20))
          v = (tail + buf)[/Linux version (\d[\w.+-]*) /n, 1]
          return v if v
          tail = buf[-64..] || buf
        end
      end
      nil
    rescue SystemCallError
      nil
    end

    # "6.18.56", or the start of the hash when the version isn't known.
    def name(k)
      return nil unless k.is_a?(Hash) && k["sha256"]
      k["version"] || "sha256 #{k['sha256'][0, 12]}"
    end

    def same?(a, b) = a.is_a?(Hash) && b.is_a?(Hash) && a["sha256"] == b["sha256"]

    # How a kernel that differs from another reads: the version, with the
    # hash when the versions are the same (a rebuild).
    def name_against(k, other)
      n = name(k)
      n && other.is_a?(Hash) && other["version"] && other["version"] == k["version"] ? "#{n} (#{k['sha256'][0, 12]})" : n
    end
  end
end
