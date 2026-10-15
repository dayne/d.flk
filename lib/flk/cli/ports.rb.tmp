module Flk
  # flk ports: host ports forwarded to machines
  class CLI
    private

    def ports_reap(_args, _o) = reap_exited(wait: true) # the tmux exit hook: no hurry, must not skip

    def ports_sync(_args, _o)
      reap_exited(wait: true)
      Ports.sync! or raise Error, "port forwarding not applied"
      puts "Port forwarding synced"
    end

    # active rows get "address": where to connect (host LAN IP:port)
    def ports_json
      active, waiting, blocked = Ports.table
      lan = Net.host_address
      { "helper_installed" => Ports.available?, "min_port" => Ports.min_port, "host_address" => lan,
        "per_address" => Ports.per_address?,
        "active" => active.map { _1.merge("address" => (a = _1["bind"] || lan) && "#{a}:#{_1['port']}") },
        "waiting" => waiting, "blocked" => blocked }
    end

    def ports_list(_args, o)
      reap_exited
      return puts(JSON.pretty_generate(ports_json)) if o[:json]
      active, waiting, blocked = Ports.table
      puts Util.yellow("Port helper not installed; run: sudo #{SETUP_HOST}\n") unless Ports.available?
      return puts("No forwarded ports (add [[services.ports]] to flk.toml)") if [active, waiting, blocked].all?(&:empty?)
      row = ->(r, status) { [Ports.label(r), r["machine"], "#{r['ip']}:#{r['internal_port']}", r["app"], status] }
      Util.table(%w[HOST_PORT MACHINE TARGET APP STATUS],
                 active.map { row[_1, "active"] } + waiting.map { row[_1, "waiting (port taken)"] } +
                 blocked.map { row[_1, "blocked: #{_1['blocked']}"] })
      return if active.empty?
      where = active.any? { _1["bind"].nil? } ? "#{Net.host_address || 'the host LAN IP'}:PORT" : "the address shown:PORT"
      puts "\nConnect to #{where} (from the host too) or the TARGET directly; " \
           "not 127.0.0.1, which isn't forwarded (for TCP: flk proxy PORT)."
    end
  end
end
