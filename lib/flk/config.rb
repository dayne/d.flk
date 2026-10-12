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

    # fly's kill_timeout: seconds between the stop signal and a hard kill.
    # Accepts 30 or "30s"/"2m", like fly. Default 10 (flk's old fixed value).
    def kill_timeout
      v = data["kill_timeout"]
      return 10 if v.nil?
      s = v.to_s.strip.downcase
      raise Error, "can't parse kill_timeout '#{v}' (want seconds, e.g. 30 or \"30s\")" unless s =~ /\A(\d+)(s|m)?\z/
      secs = $2 == "m" ? $1.to_i * 60 : $1.to_i
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
        "restart" => restart
      }
    end

    private

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
end
