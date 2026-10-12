module Flk
  # Host port forwarding. [[services.ports]] entries of *running* machines
  # become nft DNAT map entries: any host address:port -> machine ip:port.
  # Changing the map needs root, so flk hands the full list to one small
  # helper that setup-host.sh installs root-owned, with a passwordless sudo
  # rule for just that file.
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

    # Why flk won't forward a host port, or nil. DNAT on a port a host
    # process listens on would steal its inbound traffic (sshd, a database...).
    def blocked_reason(proto, port, listeners = host_listeners)
      if port < min_port
        "below #{min_port}; to allow: sudo FLK_MIN_PORT=#{port} ./setup-host.sh"
      elsif listeners.include?("#{proto}/#{port}")
        "a host process is listening on it"
      end
    end

    # "tcp/22"-style keys for host sockets bound to anything but loopback
    # (the DNAT rules skip 127.0.0.0/8). Same logic as the helper's.
    def host_listeners
      %w[tcp udp].each_with_object(Set.new) do |proto, out|
        want = proto == "tcp" ? "0A" : "07" # LISTEN / unconnected UDP
        ["/proc/net/#{proto}", "/proc/net/#{proto}6"].each do |f|
          File.foreach(f).drop(1).each do |line|
            _, laddr, _, state = line.split
            next unless state == want
            addr, port = laddr.split(":")
            next if addr.match?(/\A(\h{6}7F|0{24}01000000|0{16}FFFF0000\h{6}7F)\z/i) # 127/8, ::1, ::ffff:127/8
            out << "#{proto}/#{port.hex}"
          end
        rescue SystemCallError
          next
        end
      end
    end

    # One owner per proto/port: the first running machine to want it, by app
    # name then tap index. When it stops, the next running machine takes over.
    # Ports flk refuses to forward (see blocked_reason) go in the third list.
    def table
      owners = {}
      wanted = []
      blocked = []
      listeners = host_listeners
      App.all.each do |a|
        a.machines.select(&:running?).sort_by(&:tap_index).each do |m|
          Array(m.config["ports"]).each do |p|
            key = "#{p['proto']}/#{p['port']}"
            row = { "key" => key, "proto" => p["proto"], "port" => p["port"], "ip" => m.ip,
                    "internal_port" => p["internal_port"], "app" => a.name, "machine" => m.id }
            if (why = blocked_reason(p["proto"], p["port"], listeners))
              blocked << row.merge("blocked" => why)
              next
            end
            owners[key] ||= row
            wanted << row
          end
        end
      end
      [owners.values, wanted - owners.values, blocked]
    end

    def owner(key) = table.first.find { _1["key"] == key }

    # Push the current table to nft. Returns true on success; warns (once per
    # process) instead of failing, so machines still run without forwarding.
    def sync!
      Util.with_lock do
        active, = table
        unless available?
          return true if active.empty?
          warn_once("port forwarding isn't set up; run: sudo ./setup-host.sh")
          return false
        end
        input = active.map { "#{_1['proto']} #{_1['port']} #{_1['ip']} #{_1['internal_port']}\n" }.join
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
