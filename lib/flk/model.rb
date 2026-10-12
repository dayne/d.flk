module Flk
  # Host networking: one bridge, a pre-created pool of user-owned taps
  # (setup-host.sh), so day-to-day flk never needs sudo.
  module Net
    BRIDGE  = ENV.fetch("FLK_BRIDGE", "flkbr0")
    SUBNET  = ENV.fetch("FLK_SUBNET", "172.30.0") # /24
    GATEWAY = "#{SUBNET}.1".freeze
    POOL    = Integer(ENV.fetch("FLK_TAPS", "16"))
    DNS     = ENV.fetch("FLK_DNS", "1.1.1.1 9.9.9.9")

    module_function

    def tap(i) = "flktap#{i}"
    def ip(i)  = "#{SUBNET}.#{10 + i}"
    def mac(i) = format("06:00:ac:1e:00:%02x", 10 + i)
    def tap_exists?(i) = File.exist?("/sys/class/net/#{tap(i)}")
    def bridge_up? = File.exist?("/sys/class/net/#{BRIDGE}")

    # The host's address on the default route: where forwarded host ports
    # answer (from the host itself too). Not 127.0.0.1: the DNAT rules skip
    # loopback.
    def host_lan_ip
      out, st = Open3.capture2e("ip", "-o", "route", "get", "1.1.1.1")
      st.success? ? out[/\bsrc (\S+)/, 1] : nil
    rescue SystemCallError
      nil
    end

    # Kernel-level IP config: works even in images without iproute2.
    def kernel_ip_arg(i, hostname) = "ip=#{ip(i)}::#{GATEWAY}:255.255.255.0:#{hostname}:eth0:off"

    def used = Dir.glob(File.join(ROOT, "apps/*/machines/*/machine.json")).filter_map { Util.read_json(_1)&.dig("tap_index") }
    def free_count = (0...POOL).count { !used.include?(_1) && tap_exists?(_1) }

    def allocate!
      taken = used
      i = (0...POOL).find { !taken.include?(_1) } or
        raise Error, "tap pool exhausted (#{POOL}); re-run: sudo FLK_TAPS=#{POOL * 2} #{SETUP_HOST}"
      raise Error, "#{tap(i)} doesn't exist; run: sudo #{SETUP_HOST}" unless tap_exists?(i)
      i
    end
  end

  class App
    NAME_RE = /\A[a-z0-9][a-z0-9-]{0,62}\z/

    attr_reader :name

    def self.all = Dir.glob(File.join(ROOT, "apps", "*")).select { File.directory?(_1) }.sort.map { new(File.basename(_1)) }

    def initialize(name)
      raise Error, "invalid app name '#{name}' (lowercase letters, digits, dashes)" unless name.to_s.match?(NAME_RE)
      @name = name
    end

    def dir     = File.join(ROOT, "apps", name)
    def exists? = File.directory?(dir)
    def create! = FileUtils.mkdir_p(%w[machines volumes images].map { File.join(dir, _1) })

    def meta_path = File.join(dir, "app.json")
    def meta      = Util.read_json(meta_path, { "name" => name, "releases" => [], "created_at" => Util.now })
    def save_meta(m) = Util.write_json(meta_path, m)
    def current_release = meta["releases"].last

    def machines
      Dir.glob(File.join(dir, "machines", "*", "machine.json"))
         .map { Machine.new(self, Util.read_json(_1)) }.sort_by(&:created_at)
    end

    # Accepts an ID prefix or a machine name, like fly.
    def machine!(ref)
      found = machines.select { |m| m.id.start_with?(ref) || m.name == ref }
      raise Error, "no machine matching '#{ref}' in app #{name}" if found.empty?
      raise Error, "'#{ref}' is ambiguous: #{found.map(&:id).join(', ')}" if found.size > 1
      found.first
    end

    def secrets_path = File.join(dir, "secrets.json")
    def secrets      = Util.read_json(secrets_path, {})
    def save_secrets(h) = Util.write_json(secrets_path, h, mode: 0o600)

    # A volume flk didn't create in its own state dir (--path, import, or a
    # path edited by hand): flk never deletes its file.
    def self.external_volume?(v) = v["external"] || !File.expand_path(v["path"].to_s).start_with?("#{ROOT}/")

    def volumes_path = File.join(dir, "volumes.json")
    def volumes      = Util.read_json(volumes_path, [])
    def save_volumes(v) = Util.write_json(volumes_path, v)

    def volume!(ref)
      volumes.find { _1["id"] == ref } || volumes.find { _1["name"] == ref } ||
        raise(Error, "no volume '#{ref}' in app #{name}")
    end
  end

  class Machine
    ADJ  = %w[frosty quiet rapid amber silent misty bold lucky gentle crimson hidden swift lively mellow polar sunny].freeze
    NOUN = %w[river spruce otter raven glacier ember comet meadow falcon harbor tundra cedar lynx canyon willow aurora].freeze

    attr_reader :app, :h

    def self.generate_name = "#{ADJ.sample}-#{NOUN.sample}-#{rand(1000..9999)}"

    def initialize(app, h)
      @app = app
      @h = h
    end

    %w[id name tap_index ip mac release config created_at updated_at].each { |k| define_method(k) { h[k] } }

    def dir     = File.join(app.dir, "machines", id)
    def path(f) = File.join(dir, f)
    def session = "flk-#{id}"

    def save!
      h["updated_at"] = Util.now
      Util.write_json(path("machine.json"), h)
    end

    def pid = File.exist?(path("pid")) ? File.read(path("pid")).to_i : nil

    def running?
      p = pid or return false
      File.read("/proc/#{p}/cmdline").include?("firecracker")
    rescue SystemCallError
      false
    end

    # Firecracker went away without flk stopping it: the app exited, the
    # guest powered off, or it crashed. Its pid file (and host ports) linger.
    def exited? = !pid.nil? && !running?

    def state = running? ? "started" : "stopped"

    # What the user last asked for: start/restart/deploy/scale say "started",
    # `machine stop` says "stopped"; exiting on its own changes nothing. flk
    # resume brings back "started" machines. Machines from before this field
    # count as started if a pid file says they were running when the host
    # went down.
    def desired_state = h["desired_state"] || (pid ? "started" : "stopped")
  end
end
