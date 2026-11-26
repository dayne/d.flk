module Flk
  # Reads flk.toml, or an existing fly.toml unchanged.
  # Fly-only keys (primary_region, concurrency, checks...) are ignored.
  class AppConfig
    FILES = %w[flk.toml fly.toml].freeze
    MAX_KILL_TIMEOUT = 300 # seconds; a typo like 3000 would hang `machine stop` for 50 minutes

    attr_reader :path, :data

    def self.find(dir = Dir.pwd)
      f = FILES.map { File.join(dir, _1) }.find { File.exist?(_1) }
      f && new(f)
    end

    def initialize(path)
      @path = path
      @data = TOML.load_file(path)
    rescue TOML::ParseError => e
      raise Error, "#{File.basename(path)}: #{e.message}"
    end

    def dir = File.dirname(File.expand_path(path))

    def app
      name = data["app"].to_s
      raise Error, "#{File.basename(path)} has no 'app' name" if name.empty?
      name
    end

    def build      = data["build"].is_a?(Hash) ? data["build"] : {}
    def image      = build["image"]
    def dockerfile = build["dockerfile"] || "Dockerfile"
    def build_args = (build["args"] || {}).to_h { |k, v| [k.to_s, v.to_s] }
    def env        = (data["env"] || {}).to_h { |k, v| [k.to_s, v.to_s] }

    # fly's [experimental] cmd / entrypoint overrides
    def entrypoint = argv(data.dig("experimental", "entrypoint"))
    def cmd        = argv(data.dig("experimental", "cmd"))

    # seed (flk only): fill the volume, while it's empty, with what the
    # image has at destination (VolFS.seed!). The key is only there when on.
    def mounts
      [data["mounts"]].flatten.compact.map do |m|
        h = { "source" => m["source"].to_s, "destination" => m["destination"].to_s }
        raise Error, "[[mounts]] seed must be true or false (got '#{m['seed']}')" unless [nil, true, false].include?(m["seed"])
        h["seed"] = true if m["seed"]
        h
      end
    end

    # What's wrong with [[mounts]] that only shows later (at deploy, or as a
    # volume that can't be made): strings, like unknown_keys'.
    def mount_problems
      mounts.flat_map do |m|
        out = []
        unless m["source"].match?(VOLUME_NAME)
          out << "[[mounts]] source \"#{m['source']}\" isn't a volume name (lowercase letters, digits, underscores; " \
                 "up to 30): flk volumes create can't make it"
        end
        out << "[[mounts]] source \"#{m['source']}\" has no destination" if m["destination"].empty?
        out
      end
    end

    def internal_port
      data.dig("http_service", "internal_port") ||
        [data["services"]].flatten.compact.first&.dig("internal_port")
    end

    # internal_port's protocol ([http_service] is tcp): boot can't wait
    # for a udp port to accept connections.
    def internal_protocol
      return "tcp" if data.dig("http_service", "internal_port")
      svc = [data["services"]].flatten.compact.first or return nil
      (svc["protocol"] || "tcp").to_s.downcase
    end

    def vm = [data["vm"]].flatten.compact.first || {}

    def cpus
      return vm["cpus"].to_i if vm["cpus"]
      vm["size"].to_s =~ /-cpu-(\d+)x\z/ ? $1.to_i : 1
    end

    # [[vm]] huge_pages = "2M": back guest memory with 2M pages from a
    # reserved hugetlbfs pool (vm.nr_hugepages): fewer TLB misses for big
    # heaps, never swapped, held whether used or not. nil: 4K pages.
    # (Firecracker's "Transparent" mode left guest memory without THP on
    # Firecracker 1.17 here, so flk doesn't offer it; host-wide THP
    # `always` is the no-reservation alternative.)
    def huge_pages
      v = vm["huge_pages"]
      return nil if v.nil? || v == false || v.to_s.downcase == "none"
      unless %w[2m 2mb 2mib].include?(v.to_s.downcase)
        raise Error, "[[vm]] huge_pages must be \"2M\" (got '#{v}'); Firecracker has no 1G pages, and for THP " \
                     "set the host's /sys/kernel/mm/transparent_hugepage/enabled to always instead"
      end
      mode = "2M"
      raise Error, "[[vm]] huge_pages needs memory in whole 2MB steps (#{memory_mb}MB isn't)" if memory_mb.odd?
      mode
    end

    # Mirrors fly presets: shared-cpu-Nx = 256MB*N, performance-Nx = 2GB*N
    def memory_mb
      return vm["memory_mb"].to_i if vm["memory_mb"]
      return parse_mem(vm["memory"]) if vm["memory"]
      case vm["size"].to_s
      when /\Aperformance-cpu-(\d+)x\z/ then 2048 * $1.to_i
      when /\Ashared-cpu-(\d+)x\z/ then 256 * $1.to_i
      else 256
      end
    end

    def rootfs_extra_mb = (data.dig("flk", "rootfs_extra_mb") || 512).to_i

    # [flk] host: the flk host this app runs on (Peer). nil: wherever flk
    # is run. On that host itself the key changes nothing.
    def host
      v = data.dig("flk", "host")
      return nil if v.nil?
      unless v.is_a?(String) && v.match?(Peer::NAME) && v != Peer::LOCAL
        raise Error, "[flk] host is the name of a flk host, e.g. host = \"nexus\" (got '#{v}')"
      end
      v
    end

    # [flk] log_max_mb: the size at which this app's machines rotate
    # console.log to console.log.1 (nil: the host's FLK_LOG_MAX_MB).
    def log_max_mb
      v = data.dig("flk", "log_max_mb")
      return nil if v.nil?
      unless v.is_a?(Integer) && v >= 1
        raise Error, "[flk] log_max_mb must be a whole number of MB, at least 1 (got '#{v}')"
      end
      v
    end

    # fly's [[restart]]: what happens when the app exits on its own (not
    # when flk stops it). "on-failure" (default): restart after a non-zero
    # exit or a crash; "always": after any exit; "never" (or "no"): stay
    # stopped. retries: restarts in a row before giving up (default 10).
    RESTART_POLICIES = %w[always on-failure never].freeze

    def restart
      r = [data["restart"]].flatten.compact.first || {}
      policy = (r["policy"] || "on-failure").to_s
      policy = "never" if policy == "no"
      unless RESTART_POLICIES.include?(policy)
        raise Error, "[[restart]] policy must be always, on-failure or never (got '#{r['policy']}')"
      end
      retries = Integer(r["retries"] || r["max_retries"] || 10)
      raise Error, "[[restart]] retries can't be negative" if retries.negative?
      { "policy" => policy, "retries" => retries }
    rescue ArgumentError, TypeError
      raise Error, "[[restart]] retries must be a number"
    end

    # The app's stdin: the serial console (typing in `flk console` reaches
    # it), or /dev/null like `docker run` without -i.
    def app_stdin
      v = (data.dig("flk", "stdin") || "console").to_s
      raise Error, "[flk] stdin must be \"console\" or \"null\" (got '#{v}')" unless %w[console null].include?(v)
      v
    end

    # [flk] internal_hosts = true: APP.internal names in /etc/hosts (Hosts).
    def internal_hosts
      v = data.dig("flk", "internal_hosts")
      return false if v.nil?
      raise Error, "[flk] internal_hosts must be true or false (got '#{v}')" unless [true, false].include?(v)
      v
    end

    # 30, "30s" or "2m" as seconds, like fly's durations; default when nil.
    def self.seconds(v, default, label)
      return default if v.nil?
      s = v.to_s.strip.downcase
      raise Error, "can't parse #{label} '#{v}' (want seconds, e.g. 30 or \"30s\")" unless s =~ /\A(\d+)(s|m)?\z/
      $2 == "m" ? $1.to_i * 60 : $1.to_i
    end

    # fly's kill_timeout: seconds between the stop signal and a hard kill.
    # Accepts 30 or "30s"/"2m", like fly. Default 10 (flk's old fixed value).
    def kill_timeout
      v = data["kill_timeout"]
      secs = AppConfig.seconds(v, 10, "kill_timeout")
      if secs > MAX_KILL_TIMEOUT
        raise Error, "kill_timeout #{v} is over the #{MAX_KILL_TIMEOUT}s (#{MAX_KILL_TIMEOUT / 60}m) limit; " \
                     "stop would wait that long before killing the machine"
      end
      secs
    end

    # Host ports from [[services]] + [[services.ports]], forwarded from every
    # host address to the machine (see Ports). [http_service] means public
    # 80/443 on Fly, which a laptop shouldn't grab implicitly, so it's only
    # forwarded when [flk] http_port names a host port for it.
    def ports
      list = [data["services"]].flatten.compact.flat_map do |svc|
        proto = (svc["protocol"] || "tcp").to_s.downcase
        raise Error, "[[services]] protocol '#{proto}' not supported (tcp or udp)" unless %w[tcp udp].include?(proto)
        internal = svc["internal_port"] or raise Error, "[[services]] needs internal_port"
        [svc["ports"]].flatten.compact.map do |p|
          port = host_port(p["port"] || raise(Error, "[[services.ports]] needs port"), "[[services.ports]] port")
          { "proto" => proto, "port" => port, "internal_port" => Integer(internal) }
        end
      end
      if (hp = data.dig("flk", "http_port"))
        internal = data.dig("http_service", "internal_port") or
          raise Error, "[flk] http_port needs [http_service] internal_port to forward to"
        list << { "proto" => "tcp", "port" => host_port(hp, "[flk] http_port"), "internal_port" => Integer(internal) }
      end
      list.group_by { "#{_1['proto']}/#{_1['port']}" }.each do |key, rows|
        raise Error, "host port #{key} is listed twice" if rows.size > 1
      end
      list
    end

    # Health checks a deploy waits for before moving on: fly's [checks]
    # (type "tcp" or "http"), [[services.tcp_checks]] / [[services.http_checks]]
    # (on that service's internal_port), [[http_service.checks]], and flk's
    # own types: "log", a console line matching `match` (e.g. a game
    # server's "Done ("); "exec", a command run in the guest through the
    # agent that exits 0; "udp", a datagram to `port` that gets a reply
    # (matching `expect`). Each must pass within its grace_period (default
    # 60s) after the machine boots. One with an `interval` is also tried
    # that often while the machine runs (flk check, lib/flk/checks.rb).
    def checks
      list = []
      c = data["checks"]
      raise Error, "[checks] must be a table of named checks ([checks.NAME])" unless c.nil? || c.is_a?(Hash)
      (c || {}).each { |name, h| list << check_spec(name, h, nil) }
      [data["services"]].flatten.compact.each do |svc|
        %w[tcp http].each do |t|
          [svc["#{t}_checks"]].flatten.compact.each_with_index do |h, j|
            list << check_spec("services.#{t}_checks.#{j}", h.merge("type" => t), svc["internal_port"])
          end
        end
      end
      if (hs = data["http_service"]).is_a?(Hash)
        [hs["checks"]].flatten.compact.each_with_index do |h, j|
          list << check_spec("http_service.checks.#{j}", h.merge("type" => "http"), hs["internal_port"])
        end
      end
      list
    end

    CHECK_TYPES = %w[tcp http log exec udp disk].freeze

    def check_spec(name, h, default_port)
      raise Error, "check #{name} must be a table" unless h.is_a?(Hash)
      type = (h["type"] || "tcp").to_s
      raise Error, "check #{name}: type must be #{CHECK_TYPES.join(', ')} (got '#{type}')" unless CHECK_TYPES.include?(type)
      spec = { "name" => name.to_s, "type" => type,
               "grace_period" => AppConfig.seconds(h["grace_period"], 60, "check #{name} grace_period") }
      # also while the machine runs: flk check --due (flk-check.timer) tries it this often
      if (every = AppConfig.seconds(h["interval"], nil, "check #{name} interval"))
        raise Error, "check #{name}: interval must be at least 1s" unless every.positive?
        spec["interval"] = every
      end
      case type
      when "log"
        spec["match"] = check_regex(name, h["match"] || raise(Error, "check #{name}: type = \"log\" needs match = \"REGEX\""))
      when "exec"
        spec.merge!(exec_check(name, h))
      when "disk"
        spec.merge!(disk_check(name, h))
      else
        port = h["port"] || default_port or raise Error, "check #{name} needs a port"
        spec["port"] = Integer(port)
        spec["path"] = (h["path"] || "/").to_s if type == "http"
        spec.merge!(udp_check(name, h)) if type == "udp"
      end
      spec
    rescue ArgumentError, TypeError
      raise Error, "check #{name}: port must be a number"
    end

    # bytes: matched against a udp reply, so \xFF means the byte.
    def check_regex(name, m, bytes: false)
      bytes ? Regexp.new(m.to_s.b, Regexp::NOENCODING) : Regexp.new(m.to_s)
      m.to_s
    rescue RegexpError => e
      raise Error, "check #{name}: bad regex: #{e.message}"
    end

    # path: a directory in the machine (default /); the check fails when
    # the filesystem holding it is max_percent full or more (default 90).
    def disk_check(name, h)
      path = (h["path"] || "/").to_s
      raise Error, "check #{name}: type = \"disk\" needs path = \"/DIR\" (a directory in the machine), got '#{path}'" unless path.start_with?("/")
      max = h["max_percent"].nil? ? 90 : h["max_percent"]
      unless max.is_a?(Integer) && max.between?(1, 100)
        raise Error, "check #{name}: max_percent must be a whole number from 1 to 100 (got '#{max}')"
      end
      { "path" => path, "max_percent" => max, "timeout" => AppConfig.seconds(h["timeout"], 10, "check #{name} timeout") }
    end

    # command: an argv list, or a string run with sh -c. user: who runs it
    # (default the image's USER, as flk exec). timeout: per try, default 10s.
    def exec_check(name, h)
      cmd = h["command"]
      argv = case cmd
             when String then ["sh", "-c", cmd]
             when Array then cmd.map(&:to_s)
             end
      if argv.nil? || argv.empty? || argv.first.empty?
        raise Error, "check #{name}: type = \"exec\" needs command = [\"PROG\", \"ARG\"...] or a shell string"
      end
      spec = { "command" => argv, "timeout" => AppConfig.seconds(h["timeout"], 10, "check #{name} timeout") }
      spec["user"] = h["user"].to_s if h["user"]
      spec
    end

    # send: the datagram as text, or send_hex as hex digits (for binary
    # queries such as Steam's A2S_INFO); expect: a regex the reply must
    # match (default: any reply). timeout: per try, default 2s.
    def udp_check(name, h)
      raise Error, "check #{name}: give send or send_hex, not both" if h["send"] && h["send_hex"]
      payload = if (x = h["send_hex"])
                  hex = x.to_s.delete(" :")
                  raise Error, "check #{name}: send_hex must be hex digits (got '#{x}')" unless hex.match?(/\A(\h\h)*\z/)
                  [hex].pack("H*")
                else
                  h["send"].to_s.b
                end
      spec = { "send_hex" => payload.unpack1("H*"),
               "timeout" => AppConfig.seconds(h["timeout"], 2, "check #{name} timeout") }
      spec["expect"] = check_regex(name, h["expect"], bytes: true) if h["expect"]
      spec
    end

    # [deploy] preflight (flk only): a host command a deploy runs first, in
    # the config's directory, before any backup or build; nil when unset.
    def preflight
      d = data["deploy"]
      return nil unless d.is_a?(Hash) && d["preflight"]
      cmd = d["preflight"]
      raise Error, "[deploy] preflight must be a command string" unless cmd.is_a?(String) && !cmd.strip.empty?
      cmd
    end

    # [flk] keep_releases: release images kept for rollback (default 2).
    def keep_releases
      n = Integer(data.dig("flk", "keep_releases") || 2)
      raise Error, "[flk] keep_releases must be at least 1" if n < 1
      n
    rescue ArgumentError, TypeError
      raise Error, "[flk] keep_releases must be a number"
    end

    # Keys flk reads, plus fly.toml keys it knows and ignores, by section
    # (from ConfigKeys, which also feeds `help --all --json`); anything
    # else is likely a typo (kill_timout), so deploy and config show warn.
    # Checked one level into the sections flk uses.
    CHECKED_SECTIONS = ["", "build", "vm", "mounts", "services", "services.ports", "restart", "http_service", "check",
                        "flk", "flk.backup"].freeze

    def self.known_keys = @known_keys ||= ConfigKeys.known(CHECKED_SECTIONS)

    # ["kill_timout (did you mean kill_timeout?)", ...]
    def unknown_keys
      out = []
      look = lambda do |h, sect, prefix|
        return unless h.is_a?(Hash)
        (h.keys - AppConfig.known_keys[sect]).each do |k|
          guess = DidYouMean::SpellChecker.new(dictionary: AppConfig.known_keys[sect]).correct(k).first
          out << "#{prefix}#{k}#{" (did you mean #{guess}?)" if guess}"
        end
      end
      look[data, "", ""]
      %w[build vm mounts services restart http_service flk].each do |s|
        [data[s]].flatten.compact.each { look[_1, s, "#{s}."] }
      end
      [data["services"]].flatten.compact.each do |svc|
        next unless svc.is_a?(Hash)
        [svc["ports"]].flatten.compact.each { look[_1, "services.ports", "services.ports."] }
        %w[tcp_checks http_checks].each { |t| [svc[t]].flatten.compact.each { look[_1, "check", "services.#{t}."] } }
      end
      [data.dig("http_service", "checks")].flatten.compact.each { look[_1, "check", "http_service.checks."] } if data["http_service"].is_a?(Hash)
      data["checks"].each { |n, h| look[h, "check", "checks.#{n}."] } if data["checks"].is_a?(Hash)
      look[data.dig("flk", "backup"), "flk.backup", "flk.backup."] if data["flk"].is_a?(Hash)
      out.uniq
    end

    # [flk] bind: forward this app's host ports only on these host
    # addresses ("10.47.11.3" or a list), or on all of them ("all", which
    # also overrides a host-wide bind). nil: the host default.
    def bind = AppConfig.bind_list(data.dig("flk", "bind"), "[flk] bind")

    def self.bind_list(v, label)
      return nil if v.nil?
      list = Array(v).map(&:to_s)
      raise Error, "#{label} is empty" if list.empty?
      return ["all"] if list == ["all"]
      list.each do |a|
        ok = a.match?(/\A\d{1,3}(\.\d{1,3}){3}\z/) && a.split(".").all? { _1.to_i <= 255 }
        raise Error, "#{label} '#{a}' isn't an IPv4 address (or \"all\")" unless ok
        raise Error, "#{label} #{a}: loopback isn't forwarded; use the host's LAN address" if a.start_with?("127.", "0.")
        raise Error, "#{label} #{a} is a machine address (#{Net::SUBNET}.0/24), not the host's" if a.start_with?("#{Net::SUBNET}.")
      end
      raise Error, "#{label} lists an address twice" if list.uniq.size < list.size
      list
    end

    # Ports below the helper's floor (1024 unless setup-host.sh was given
    # FLK_MIN_PORT) are refused here, so deploy fails before anything boots.
    def host_port(v, label)
      port = Integer(v)
      raise Error, "#{label} #{port} isn't a valid port" unless port.between?(1, 65_535)
      if port < (min = Ports.min_port)
        raise Error, "#{label} #{port} is below #{min}, where host services live; " \
                     "use a higher port, or allow it: #{Util.setup_host_cmd("FLK_MIN_PORT=#{port}")}"
      end
      port
    rescue ArgumentError, TypeError
      raise Error, "#{label} '#{v}' isn't a port number"
    end

    # The snapshot each machine keeps, like a Fly machine's own config.
    def machine_config
      env.each_key { |k| raise Error, "[env] key '#{k}' isn't a valid variable name" unless k.match?(ENV_KEY) }
      {
        "cpus" => cpus,
        "memory_mb" => memory_mb,
        "env" => env,
        "mount_specs" => mounts,
        "internal_port" => internal_port,
        "internal_protocol" => internal_protocol,
        "ports" => ports,
        "kill_timeout" => kill_timeout,
        "kernel_args" => data.dig("flk", "kernel_args"),
        "stdin" => app_stdin,
        "restart" => restart,
        "bind" => bind,
        "checks" => checks,
        "huge_pages" => huge_pages,
        "internal_hosts" => internal_hosts,
        "log_max_mb" => log_max_mb
      }
    end

    # [flk.backup]: how `flk volumes backup` keeps the app from writing
    # while its volume is copied.
    #   mode = "stop"  (default) stop the machine, copy, start it again
    #          "live"  copy while it runs, after the pre hooks (the app must
    #                  stop writing and flush, e.g. Minecraft's save-off)
    #          "pause" pause the VM during the copy: a crash-consistent
    #                  image (like a power cut), instant on XFS/btrfs
    #   pre / post = hooks, in order: "a host command" (run in this file's
    #     directory) or { console = "line", wait = "REGEX", timeout = 60 }
    #   settle = seconds between the pre hooks and the copy (default 5): the
    #     guest writes its cached data out within about a second
    #   keep = backups to keep of each volume (else host backup_keep, else 7)
    BACKUP_MODES = %w[stop live pause].freeze

    def backup
      b = data.dig("flk", "backup") || {}
      raise Error, "[flk.backup] must be a table" unless b.is_a?(Hash)
      mode = (b["mode"] || "stop").to_s
      raise Error, "[flk.backup] mode must be stop, live or pause (got '#{mode}')" unless BACKUP_MODES.include?(mode)
      hooks = %w[pre post].to_h { |k| [k, Array(b[k]).map { backup_hook(_1, k) }] }
      verify = b["verify"]
      raise Error, "[flk.backup] verify is a host command (a string)" unless verify.nil? || verify.is_a?(String)
      bd = b["before_deploy"]
      raise Error, "[flk.backup] before_deploy is true or false" unless [nil, true, false].include?(bd)
      { "mode" => mode, "settle" => Integer(b["settle"] || 5),
        "keep" => b["keep"] && Integer(b["keep"]), "verify" => verify, "before_deploy" => bd == true }.merge(hooks)
    rescue ArgumentError, TypeError
      raise Error, "[flk.backup] settle and keep must be numbers"
    end

    private

    def backup_hook(h, key)
      case h
      when String then { "run" => h }
      when Hash
        raise Error, "[flk.backup] #{key} hook needs console = \"...\" (or a plain string: a host command)" unless h["console"]
        { "console" => h["console"].to_s, "wait" => h["wait"]&.to_s, "timeout" => Integer(h["timeout"] || 60) }
      else raise Error, "[flk.backup] #{key} hooks are strings (host commands) or { console = ... } tables"
      end
    end

    def argv(v)
      return nil if v.nil?
      v.is_a?(String) ? v.shellsplit : Array(v).map(&:to_s)
    end

    def parse_mem(v)
      return v if v.is_a?(Integer) # fly treats bare ints as MB
      s = v.to_s.strip.downcase
      raise Error, "can't parse memory '#{v}'" unless s =~ /\A(\d+(?:\.\d+)?)\s*(gb|g|mb|m)?\z/
      ($2.to_s.start_with?("g") ? $1.to_f * 1024 : $1.to_f).to_i
    end
  end

  # Settings for this host (not an app): ~/.config/flk/host.toml.
  #   backup_dir  = "/data/flk-backups"   # where flk volumes backup copies to
  #   backup_keep = 7                     # backups kept per volume
  #   address     = "10.47.11.3"          # the address flk tells people to use
  #   bind        = "10.47.11.3"          # forward ports only there (default
  #                                       # for apps without [flk] bind)
  #   backup_copy_to   = "/mnt/usb/flk" or "user@nas:/srv/flk"  # after each
  #                                       # backup, copy it there too
  #   backup_copy_keep = 7                # copies kept there per volume
  #   backup_copy_warn_days = 8           # doctor warns when the newest copy is older
  #   backup_warn_days = 2                # doctor warns when a backed-up volume has
  #                                       # no backup that recent (unset: not checked)
  #   disk_warn_percent = 90              # doctor warns when the disk under flk's
  #                                       # state or volumes is this full
  #   name = "mud"                        # this host's name among flk hosts
  #                                       # (default: the hostname); an app whose
  #                                       # [flk] host says it runs here
  #   [peers]                             # other flk hosts: name = ssh destination
  #     nexus = "dayne@10.47.11.85"       # (a name not listed is its own destination)
  module Host
    # FLK_HOST_CONFIG (tests) swaps the file for this process. Except for
    # `bind`: the port map is one for the whole host, and every flk process
    # rewrites all of it, so bind always comes from the host's own file
    # (else a test run would move every app's ports; see port_settings).
    HOST_FILE = File.join(ENV["XDG_CONFIG_HOME"] || File.join(Dir.home, ".config"), "flk", "host.toml")
    PATH = ENV["FLK_HOST_CONFIG"] || HOST_FILE
    KEYS = %w[backup_dir backup_keep address bind backup_copy_to backup_copy_keep backup_copy_warn_days
              backup_warn_days disk_warn_percent name peers].freeze
    NUMBERS = { "disk_warn_percent" => 1..100, "backup_warn_days" => 1..3650 }.freeze

    module_function

    def settings(path = PATH)
      return {} unless File.exist?(path)
      h = TOML.load_file(path)
      unknown = h.keys - KEYS
      raise Error, "#{path}: unknown setting(s) #{unknown.join(', ')} (known: #{KEYS.join(', ')})" if unknown.any?
      AppConfig.bind_list(h["address"], "#{path}: address")&.then do |a|
        raise Error, "#{path}: address is one address" unless a.size == 1 && a != ["all"]
      end
      h["bind"] = AppConfig.bind_list(h["bind"], "#{path}: bind") if h.key?("bind")
      raise Error, "#{path}: name is a host name (got '#{h['name']}')" unless h["name"].nil? || h["name"].to_s.match?(Peer::NAME)
      unless h["peers"].nil? || (h["peers"].is_a?(Hash) && h["peers"].all? { |k, v| k.match?(Peer::NAME) && v.to_s.match?(Peer::NAME) })
        raise Error, "#{path}: [peers] lists other flk hosts as name = \"ssh destination\""
      end
      NUMBERS.each do |key, range|
        next if h[key].nil? || (h[key].is_a?(Integer) && range.cover?(h[key]))
        raise Error, "#{path}: #{key} must be a whole number from #{range.min} to #{range.max} (got '#{h[key]}')"
      end
      h
    rescue TOML::ParseError => e
      raise Error, "#{path}: #{e.message}"
    end


    # The settings that shape the host-wide port map (bind): always the
    # host's own file, whatever FLK_HOST_CONFIG says.
    def port_settings = settings(HOST_FILE)
  end
end
