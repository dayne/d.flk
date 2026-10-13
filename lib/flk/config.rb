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

    def mounts
      [data["mounts"]].flatten.compact.map do |m|
        { "source" => m["source"].to_s, "destination" => m["destination"].to_s }
      end
    end

    def internal_port
      data.dig("http_service", "internal_port") ||
        [data["services"]].flatten.compact.first&.dig("internal_port")
    end

    def vm = [data["vm"]].flatten.compact.first || {}

    def cpus
      return vm["cpus"].to_i if vm["cpus"]
      vm["size"].to_s =~ /-cpu-(\d+)x\z/ ? $1.to_i : 1
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
    # own type = "log": a console line matching `match` (e.g. a game
    # server's "Done ("). Each must pass within its grace_period (default
    # 60s) after the machine boots.
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

    CHECK_TYPES = %w[tcp http log].freeze

    def check_spec(name, h, default_port)
      raise Error, "check #{name} must be a table" unless h.is_a?(Hash)
      type = (h["type"] || "tcp").to_s
      raise Error, "check #{name}: type must be tcp, http or log (got '#{type}')" unless CHECK_TYPES.include?(type)
      spec = { "name" => name.to_s, "type" => type,
               "grace_period" => AppConfig.seconds(h["grace_period"], 60, "check #{name} grace_period") }
      if type == "log"
        m = h["match"] or raise Error, "check #{name}: type = \"log\" needs match = \"REGEX\""
        begin
          Regexp.new(m.to_s)
        rescue RegexpError => e
          raise Error, "check #{name}: bad match regex: #{e.message}"
        end
        spec["match"] = m.to_s
      else
        port = h["port"] || default_port or raise Error, "check #{name} needs a port"
        spec["port"] = Integer(port)
        spec["path"] = (h["path"] || "/").to_s if type == "http"
      end
      spec
    rescue ArgumentError, TypeError
      raise Error, "check #{name}: port must be a number"
    end

    # [flk] keep_releases: release images kept for rollback (default 2).
    def keep_releases
      n = Integer(data.dig("flk", "keep_releases") || 2)
      raise Error, "[flk] keep_releases must be at least 1" if n < 1
      n
    rescue ArgumentError, TypeError
      raise Error, "[flk] keep_releases must be a number"
    end

    # Keys flk reads, plus fly.toml keys it knows and ignores, by section;
    # anything else is likely a typo (kill_timout), so deploy and config
    # show warn. Checked one level into the sections flk uses.
    KNOWN_KEYS = {
      "" => %w[app primary_region kill_signal kill_timeout swap_size_mb console_command build deploy env
               experimental files http_service services mounts processes statics vm checks metrics restart flk],
      "build" => %w[image dockerfile args build-target build_target ignorefile builder builtin buildpacks settings],
      "vm" => %w[size memory memory_mb cpus cpu_kind gpus gpu_kind processes kernel_args host_dedication_id persist_rootfs],
      "mounts" => %w[source destination processes initial_size auto_extend_size_threshold auto_extend_size_increment
                     auto_extend_size_limit snapshot_retention scheduled_snapshots],
      "services" => %w[internal_port protocol ports concurrency tcp_checks http_checks auto_stop_machines
                       auto_start_machines min_machines_running processes script_checks],
      "services.ports" => %w[port handlers force_https start_port end_port tls_options http_options proxy_proto_options],
      "restart" => %w[policy retries max_retries processes],
      "http_service" => %w[internal_port force_https auto_stop_machines auto_start_machines min_machines_running
                           processes concurrency checks http_options tls_options],
      "check" => %w[type port path method grace_period interval timeout headers protocol tls_skip_verify
                    tls_server_name match processes],
      "flk" => %w[http_port kernel_args rootfs_extra_mb stdin bind backup keep_releases],
      "flk.backup" => %w[mode pre post settle keep]
    }.freeze

    # ["kill_timout (did you mean kill_timeout?)", ...]
    def unknown_keys
      out = []
      look = lambda do |h, sect, prefix|
        return unless h.is_a?(Hash)
        (h.keys - KNOWN_KEYS[sect]).each do |k|
          guess = DidYouMean::SpellChecker.new(dictionary: KNOWN_KEYS[sect]).correct(k).first
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
                     "use a higher port, or allow it: sudo FLK_MIN_PORT=#{port} #{SETUP_HOST}"
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
        "ports" => ports,
        "kill_timeout" => kill_timeout,
        "kernel_args" => data.dig("flk", "kernel_args"),
        "stdin" => app_stdin,
        "restart" => restart,
        "bind" => bind,
        "checks" => checks
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
      { "mode" => mode, "settle" => Integer(b["settle"] || 5),
        "keep" => b["keep"] && Integer(b["keep"]) }.merge(hooks)
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
  module Host
    # FLK_HOST_CONFIG (tests) swaps the file for this process. Except for
    # `bind`: the port map is one for the whole host, and every flk process
    # rewrites all of it, so bind always comes from the host's own file
    # (else a test run would move every app's ports; see port_settings).
    HOST_FILE = File.join(ENV["XDG_CONFIG_HOME"] || File.join(Dir.home, ".config"), "flk", "host.toml")
    PATH = ENV["FLK_HOST_CONFIG"] || HOST_FILE
    KEYS = %w[backup_dir backup_keep address bind].freeze

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
      h
    rescue TOML::ParseError => e
      raise Error, "#{path}: #{e.message}"
    end

    # The settings that shape the host-wide port map (bind): always the
    # host's own file, whatever FLK_HOST_CONFIG says.
    def port_settings = settings(HOST_FILE)
  end
end
