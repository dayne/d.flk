module Flk
  # flk context: what flk sees now, and the next steps
  class CLI
    private

    def cmd_context(_args, o)
      reap_exited
      c = o[:all] ? host_context(no_host: o[:no_host]) : context(no_host: o[:no_host])
      return puts(JSON.pretty_generate(c)) if o[:json]
      puts(o[:all] ? host_context_text(c) : context_text(c))
    end

    # Every app at once: what's running where, what's reachable, what's wrong.
    def host_context(no_host: false)
      host = no_host ? [] : doctor_checks
      steps = host.reject { _1["status"] == "pass" }
                  .map { "#{_1['status'] == 'fail' ? 'fix' : 'optional'}: #{_1['label']} -> #{_1['hint']}" }
      apps = App.all.map do |a|
        app_steps = []
        cfg = config_for(a.name)
        h = app_context(a, cfg, app_steps)
        steps.concat(app_steps.reject { _1.start_with?("all good") }.map { "#{a.name}: #{_1}" })
        h
      end
      { "schema" => JSON_SCHEMA,
        "flk" => { "version" => VERSION, "state_dir" => ROOT, "source" => File.dirname(SHARE) },
        "mount_dirs" => mount_dirs,
        "host" => if no_host
                    { "lan_ip" => Net.host_lan_ip, "address" => Net.host_address }
                  else
                    { "ok" => host.none? { _1["status"] == "fail" }, "problems" => host.reject { _1["status"] == "pass" },
                      "lan_ip" => Net.host_lan_ip, "address" => Net.host_address, "boot_service" => host.any? { _1["label"].start_with?("boot service (") },
                      "services" => services_status }
                  end,
        "apps" => apps, "next_steps" => steps }
    end

    def host_context_text(c)
      h = c["host"]
      health = if h.key?("ok")
                 "#{h['ok'] ? 'ready' : 'NOT ready'}, address #{h['address'] || h['lan_ip'] || '?'}, " \
                   "boot service #{h['boot_service'] ? 'installed' : 'missing'}"
               else
                 "not checked (--no-host), address #{h['address'] || h['lan_ip'] || '?'}"
               end
      out = ["# flk host overview", "",
             "flk #{c['flk']['version']}  state: #{c['flk']['state_dir']}  source: #{c['flk']['source']}",
             "host: #{health}", ""]
      return (out << "No apps. Start with: flk help first-app").join("\n") if c["apps"].empty?
      c["apps"].each do |a|
        ms = Array(a["machines"])
        rel = a["release"]
        out << "## #{a['name']}  (#{rel ? "v#{rel['version']}" : 'no release'}, #{ms.count { _1['state'] == 'started' }}/#{ms.size} started)"
        ms.each do |m|
          flag = m["state"] != "started" && m["desired_state"] == "started" ? "  <- should be running" : ""
          out << "  #{m['id']} [#{m['name']}] #{m['state']} #{m['ip']}#{m['internal_port'] ? ":#{m['internal_port']}" : ''}#{flag}"
        end
        Array(a["config_warnings"]).each { out << "  ⚠ #{File.basename(a['config_path'] || 'flk.toml')}: #{_1}" }
        Array(a.dig("ports", "active")).each { out << "  port #{Ports.label(_1)} -> #{_1['address'] || "LAN IP:#{_1['port']}"}" }
        Array(a.dig("ports", "blocked")).each { out << "  port #{_1['key']} blocked: #{_1['blocked']}" }
        vols = Array(a["volumes"])
        out << "  volumes: #{vols.map { "#{_1['name']} #{_1['size_gb']}GB#{' (external)' if _1['external']}" }.join(', ')}" if vols.any?
        out << ""
      end
      out << "## Needs attention"
      c["next_steps"].each { out << "- #{_1}" }
      out << "- nothing" if c["next_steps"].empty?
      out << "" << "Details for one app: flk context -a APP.  Commands by task: flk help cheatsheet"
      out.join("\n")
    end

    # Everything an agent (or a person) needs to pick the next command,
    # gathered without failing: problems become next_steps.
    def context(no_host: false)
      host = no_host ? [] : doctor_checks
      c = { "schema" => JSON_SCHEMA,
            "flk" => { "version" => VERSION, "state_dir" => ROOT, "source" => File.dirname(SHARE),
                       "reference" => "flk help --all" },
            "host" => if no_host
                        { "lan_ip" => Net.host_lan_ip, "address" => Net.host_address }
                      else
                        { "ok" => host.none? { _1["status"] == "fail" }, "problems" => host.reject { _1["status"] == "pass" } }
                      end,
            "cwd" => Dir.pwd, "config" => nil, "app" => nil, "other_apps" => [], "next_steps" => [] }
      steps = c["next_steps"]
      Array(c["host"]["problems"]).each { steps << "#{_1['status'] == 'fail' ? 'fix' : 'optional'}: #{_1['label']} -> #{_1['hint']}" }

      cfg = begin
        AppConfig.find
      rescue Error => e
        c["config"] = { "error" => e.message }
        steps << "fix the config file: #{e.message}"
        nil
      end
      if cfg
        c["config"] = { "file" => cfg.path, "app" => (cfg.app rescue nil) }
        begin
          mc = cfg.machine_config
          c["config"]["machine_config"] = mc
        rescue Error => e
          c["config"]["error"] = e.message
          steps << "fix #{File.basename(cfg.path)}: #{e.message}"
        end
      end

      name = @app_name || c.dig("config", "app")
      if name
        c["app"] = app_context(App.new(name), cfg&.app == name ? cfg : config_for(name), steps)
      elsif !c["config"]
        steps << "no flk.toml or fly.toml in #{Dir.pwd}: cd to an app directory, pass -a APP, or create one with: flk launch"
      end
      c["other_apps"] = apps_summary.reject { _1["name"] == name }
      c
    end

    def app_context(a, cfg, steps)
      h = { "name" => a.name, "registered" => a.exists?, "config_warnings" => warning_strings(cfg) }
      unless a.exists?
        steps << (cfg ? "register the app: flk launch --no-deploy (then flk deploy)" : "app '#{a.name}' doesn't exist; see: flk apps list")
        return h
      end
      h["config_warnings"].each { steps << "optional: #{File.basename(cfg.path)}: #{_1}" }
      ms = a.machines
      rel = a.current_release
      h.merge!("home" => a.dir, "config_path" => a.meta["config_path"],
               "release" => rel, "releases" => a.meta["releases"].size, "scale" => a.meta["scale"],
               "machines" => ms.map { machine_json(_1) }, "volumes" => a.volumes,
               "secrets" => a.secrets.keys)
      ports = ports_json
      h["ports"] = %w[active waiting blocked].to_h { |k| [k, ports[k].select { _1["app"] == a.name }] }

      # volumes [[mounts]] will need: one unattached per machine per source
      want = [ms.size, a.meta["scale"] || 1].max
      Array(cfg&.mounts).each do |mt|
        have = a.volumes.count { _1["name"] == mt["source"] }
        next if have >= want
        n = want - have
        steps << "[[mounts]] source '#{mt['source']}' needs #{n} more volume#{'s' if n > 1}: " \
                 "flk volumes create #{mt['source']} --size 1#{" (run #{n} times)" if n > 1}"
      end
      unless a.meta["config_path"]
        steps << "flk doesn't know where #{a.name}'s flk.toml is: run flk launch --no-deploy (or flk deploy) once in its directory"
      end
      if rel.nil?
        steps << (cfg ? "deploy the first release: flk deploy" : "no release yet; run flk deploy from the app directory")
      elsif ms.empty?
        steps << "no machines; flk deploy (or flk scale count 1)"
      end
      ms.reject(&:running?).each do |m|
        steps << if m.h.dig("restarts", "gave_up_at")
                   "machine #{m.id} [#{m.name}] kept failing; its restart policy gave up after " \
                   "#{m.h.dig('restarts', 'count')} restarts: flk logs -i #{m.id} --no-tail, fix, then flk machine start #{m.id}"
                 elsif m.desired_state == "started"
                   "machine #{m.id} [#{m.name}] should be running but isn't (it exited, or the host restarted); " \
                   "see why: flk logs -i #{m.id} --no-tail; bring it back: flk resume"
                 else
                   "machine #{m.id} [#{m.name}] is stopped; start it: flk machine start #{m.id}"
                 end
      end
      h["ports"]["blocked"].each { steps << "host port #{_1['key']} not forwarded: #{_1['blocked']}" }
      h["ports"]["waiting"].each { steps << "host port #{_1['key']} is held by another machine; this one gets it when that stops" }
      if rel && rel["version"]
        # newer than current = a failed release that deploy --no-rollback left running
        failed, other = ms.partition { stranded_on_failed?(a, _1, rel) }
        failed.each do |m|
          steps << "machine #{m.id} [#{m.name}] is on v#{m.release}, which failed its health checks (left by --no-rollback): " \
                   "see flk logs -i #{m.id} --no-tail; then flk releases rollback v#{rel['version']}, or fix and flk deploy"
        end
        steps << "some machines run an older release; flk deploy rolls them" if cfg && other.any? { _1.release != rel["version"] }
      end
      up = ms.select(&:running?)
      if up.any? && steps.none? { !_1.start_with?("optional:") }
        port = up.first.config["internal_port"]
        steps << "all good#{port ? "; try: curl http://#{up.first.ip}:#{port}/" : ''} (logs: flk logs)"
      end
      h
    end

    def context_text(c)
      out = ["# flk context", "",
             "flk #{c['flk']['version']}  state: #{c['flk']['state_dir']}  full reference: flk help --all", "",
             "## Host", c["host"].key?("ok") ? (c["host"]["ok"] ? "ready" : "NOT ready") : "not checked (--no-host)"]
      Array(c["host"]["problems"]).each { out << "- #{_1['status']}: #{_1['label']} -> #{_1['hint']}" }
      out << "" << "## App" << "cwd: #{c['cwd']}"
      if (cf = c["config"])
        out << "config: #{cf['file'] || '(unreadable)'}#{" -- ERROR: #{cf['error']}" if cf['error']}"
      else
        out << "config: none in this directory"
      end
      if (a = c["app"])
        out << "app: #{a['name']}#{' (not registered)' unless a['registered']}"
        Array(a["config_warnings"]).each { out << "⚠ #{File.basename(a['config_path'] || 'flk.toml')}: #{_1}" }
        if a["registered"]
          rel = a["release"]
          out << "release: #{rel ? "v#{rel['version']} (#{rel['tag']}), #{a['releases']} total" : 'none'}"
          out << "machines: #{a['machines'].empty? ? 'none' : ''}"
          a["machines"].each do |m|
            out << "- #{m['id']} [#{m['name']}] #{m['state']} v#{m['release']} #{m['ip']}" \
                   "#{m['internal_port'] ? ":#{m['internal_port']}" : ''}"
          end
          out << "volumes: #{a['volumes'].map { "#{_1['name']}=#{_1['id']}(#{_1['attached_machine'] || 'free'})" }.join(', ').then { _1.empty? ? 'none' : _1 }}"
          out << "secrets: #{a['secrets'].empty? ? 'none' : a['secrets'].join(', ')}"
          ports = a["ports"]
          rows = ports["active"].map { "#{Ports.label(_1)} -> #{_1['ip']}:#{_1['internal_port']} (active; connect to #{_1['address'] || "host LAN IP:#{_1['port']}"}, not 127.0.0.1)" } +
                 ports["waiting"].map { "#{_1['key']} (waiting: held by another machine)" } +
                 ports["blocked"].map { "#{_1['key']} (blocked: #{_1['blocked']})" }
          out << "host ports: #{rows.empty? ? 'none' : rows.join('; ')}"
        end
      else
        out << "app: none (pass -a APP or cd to a directory with flk.toml)"
      end
      unless c["other_apps"].empty?
        out << "" << "## Other apps"
        c["other_apps"].each { out << "- #{_1['name']}: #{_1['started']}/#{_1['machines']} machines started" }
      end
      out << "" << "## Next steps"
      c["next_steps"].each { out << "- #{_1}" }
      out << "- nothing obvious; see: flk help" if c["next_steps"].empty?
      out.join("\n")
    end
  end
end
