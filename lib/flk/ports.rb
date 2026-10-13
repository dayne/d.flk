module Flk
  # Host port forwarding. [[services.ports]] entries of *running* machines
  # become nft DNAT map entries: host address:port -> machine ip:port, on
  # every host address, or only on the addresses the app binds to ([flk]
  # bind, or bind in the host settings). Changing the maps needs root, so
  # flk hands the full list to one small helper that setup-host.sh installs
  # root-owned, with a passwordless sudo rule for just that file.
  module Ports
    module_function

    HELPER = "/usr/local/libexec/flk-ports"
    DEFAULT_MIN_PORT = 1024

    def available? = File.executable?(HELPER)

    # Lowest host port the installed helper accepts (setup-host.sh bakes in
    # FLK_MIN_PORT). The helper enforces it; flk reads it to fail early.
    def min_port
      File.read(HELPER)[/^min_port="(\d+)"/, 1]&.to_i || DEFAULT_MIN_PORT
    rescue SystemCallError
      DEFAULT_MIN_PORT
    end

    # Does the installed helper (and so the nft table setup-host.sh made
    # with it) forward on single addresses? Older ones forward on all.
    def per_address?
      File.read(HELPER).include?("addr_ports")
    rescue SystemCallError
      false
    end

    # Why flk won't forward a host port (on one address, or all when bind
    # is nil), or nil. DNAT on a port a host process listens on would steal
    # its inbound traffic (sshd, a database...).
    def blocked_reason(proto, port, listeners = host_listeners, bind: nil)
      if port < min_port
        "below #{min_port}; to allow: sudo FLK_MIN_PORT=#{port} #{SETUP_HOST}"
      elsif (l = listeners.find { |pr, po, addr| pr == proto && po == port && (bind.nil? || addr == "*" || addr == bind) })
        "a host process is listening on it#{" (on #{l[2] == '*' ? 'all addresses' : l[2]})" if bind}"
      end
    end

    # [proto, port, address] of host sockets bound to anything but loopback
    # (the DNAT rules skip 127.0.0.0/8). address is "*" for all addresses
    # (0.0.0.0, or :: which takes IPv4 too), dotted IPv4, or "v6" for an
    # IPv6-only one. Same logic as the helper's.
    def host_listeners
      %w[tcp udp].each_with_object(Set.new) do |proto, out|
        want = proto == "tcp" ? "0A" : "07" # LISTEN / unconnected UDP
        ["/proc/net/#{proto}", "/proc/net/#{proto}6"].each do |f|
          File.foreach(f).drop(1).each do |line|
            _, laddr, _, state = line.split
            next unless state == want
            hex, port = laddr.split(":")
            addr = proc_addr(hex) or next
            out << [proto, port.hex, addr]
          end
        rescue SystemCallError
          next
        end
      end
    end

    # A /proc/net address (little-endian hex words) as "*", dotted IPv4 or
    # "v6"; nil for loopback.
    def proc_addr(hex)
      v4 = ->(h) { [h].pack("H*").unpack("C4").reverse.join(".") }
      case hex.upcase
      when /\A0{8}\z/, /\A0{32}\z/ then "*"
      when /\A\h{8}\z/ then (a = v4[hex]).start_with?("127.") ? nil : a
      when "0" * 24 + "01000000" then nil # ::1
      when /\A0{16}FFFF0000(\h{8})\z/ then (a = v4[$1]).start_with?("127.") ? nil : a
      else "v6"
      end
    end

    # The addresses a machine's ports answer on: its [flk] bind ("all"
    # overrides the host default), else the host's bind, else nil (all).
    # With a helper that predates per-address maps, all: dropping the
    # forwarding instead would take the app offline (doctor says to update).
    def binds(m)
      b = m.config["bind"] || Array(Host.settings["bind"]).then { _1.empty? ? nil : _1 }
      b.nil? || b.include?("all") || !per_address? ? [nil] : b
    rescue Error
      [nil]
    end

    # One owner per address/proto/port: the first running machine to want
    # it, by app name then tap index. When it stops, the next running
    # machine takes over. A port bound to an address and the same port on
    # all addresses can coexist: the bound one wins on its address. Ports
    # flk refuses to forward (see blocked_reason) go in the third list.
    def table
      owners = {}
      wanted = []
      blocked = []
      listeners = host_listeners
      App.all.each do |a|
        a.machines.select(&:running?).sort_by(&:tap_index).each do |m|
          Array(m.config["ports"]).product(binds(m)).each do |p, bind|
            key = "#{p['proto']}/#{p['port']}"
            row = { "key" => key, "bind" => bind, "proto" => p["proto"], "port" => p["port"], "ip" => m.ip,
                    "internal_port" => p["internal_port"], "app" => a.name, "machine" => m.id }
            if (why = blocked_reason(p["proto"], p["port"], listeners, bind: bind))
              blocked << row.merge("blocked" => why)
              next
            end
            owners[[bind, key]] ||= row
            wanted << row
          end
        end
      end
      [owners.values, wanted - owners.values, blocked]
    end

    def owner(key, bind = nil) = table.first.find { _1["key"] == key && _1["bind"] == bind }

    # "10.47.11.3:tcp/25565" for a bound row, "tcp/25565" for all addresses.
    def label(row) = row["bind"] ? "#{row['bind']}:#{row['key']}" : row["key"]

    # Push the current table to nft. Returns true on success; warns (once per
    # process) instead of failing, so machines still run without forwarding.
    def sync!
      Util.with_lock do
        active, = table
        unless available?
          return true if active.empty?
          warn_once("port forwarding isn't set up; run: sudo #{SETUP_HOST}")
          return false
        end
        input = active.map { "#{_1['proto']} #{_1['port']} #{_1['ip']} #{_1['internal_port']}#{" #{_1['bind']}" if _1['bind']}\n" }.join
        out, st = Open3.capture2e("sudo", "-n", HELPER, "replace", stdin_data: input)
        warn_once("port forwarding update failed: #{out.strip}") unless st.success?
        st.success?
      end
    rescue SystemCallError => e # e.g. no sudo binary
      warn_once("port forwarding update failed: #{e.message}")
      false
    end

    def warn_once(msg)
      @warned ||= {}
      return if @warned[msg]
      @warned[msg] = true
      warn Util.yellow("    ⚠ #{msg}")
    end
  end
end
