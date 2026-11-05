module Flk
  # flk machine, scale: machine lifecycle, creating and booting machines
  class CLI
    private

    def machine_table(a)
      ms = a.machines
      return puts("No machines. Run: flk deploy") if ms.empty?
      Util.table(%w[ID NAME STATE RELEASE IP CPUS MEMORY VOLUMES UPDATED], ms.map do |m|
        [m.id, m.name, m.state, "v#{m.release}", m.ip, m.config["cpus"], "#{m.config['memory_mb']}MB",
         m.config["mounts"].map { _1["volume"] }.join(",").then { _1.empty? ? "-" : _1 }, Util.ago(m.updated_at)]
      end)
    end

    # A machine as list/status/context JSON show it.
    def machine_json(m)
      { "id" => m.id, "name" => m.name, "state" => m.state, "desired_state" => m.desired_state,
        "pid" => m.running? ? m.pid : nil, "restart" => m.restart_policy, "restarts" => m.h["restarts"],
        "release" => m.release, "ip" => m.ip,
        "cpus" => m.config["cpus"], "memory_mb" => m.config["memory_mb"], "huge_pages" => m.config["huge_pages"],
        "internal_port" => m.config["internal_port"], "ports" => Array(m.config["ports"]),
        "volumes" => Array(m.config["mounts"]),
        # [flk] internal_hosts: the names on its /etc/hosts line ([] when off)
        "internal_names" => Hosts.wants?(m) ? Hosts.names(m) : [],
        "created_at" => m.created_at, "updated_at" => m.updated_at }
    end

    def machine_list(_args, o)
      reap_exited
      return puts(JSON.pretty_generate(app.machines.map { machine_json(_1) })) if o[:json]
      machine_table(app)
    end

    def machine_start(args, _o) = each_ref(pick_ids!("start", args)) { |m| boot(m, "Machine #{m.id} [#{m.name}] started") }
    def machine_stop(args, _o)
      each_ref(pick_ids!("stop", args)) { |m| stop_machine(m) }
      next_step("flk machine start #{args.join(' ')}")
    end
    def machine_restart(args, _o) = each_ref(pick_ids!("restart", args)) { |m| restart_machine(m) }

    def stop_machine(m)
      VM.stop(m)
      puts "Machine #{m.id} [#{m.name}] stopped (stays stopped, also after reboots)"
    end

    def restart_machine(m)
      VM.stop(m)
      boot(m, "Machine #{m.id} [#{m.name}] restarted")
    end

    # `machine stop` with no ID never guesses: it names the machines and
    # the app-wide command instead.
    def pick_ids!(verb, args)
      return args if args.any?
      ms = app.machines
      raise Error.new("#{app.name} has no machines", next_steps: ["flk deploy"]) if ms.empty?
      list = ms.map { "#{_1.id} [#{_1.name}] #{_1.state}" }.join(", ")
      raise Error.new("which machine? #{app.name}'s machines: #{list}",
                      next_steps: ["flk machine #{verb} #{ms.first.id}", "flk #{verb} (all of #{app.name}'s machines)"])
    end

    def machine_hosts_sync(_args, _o) = Hosts.sync!

    # flk start | stop | restart: every machine of the app.
    def cmd_start(_args, _o)
      ms = app.machines
      raise Error.new("#{app.name} has no machines", next_steps: ["flk deploy"]) if ms.empty?
      todo = ms.reject(&:running?)
      return puts("Every machine of #{app.name} is already running") if todo.empty?
      todo.each { |m| boot(m, "Machine #{m.id} [#{m.name}] started") }
      next_step("flk status", "flk logs")
    end

    def cmd_stop(_args, _o)
      todo = app.machines.select(&:running?)
      return puts("Nothing of #{app.name} is running") if todo.empty?
      todo.each { stop_machine(_1) }
      next_step("flk start")
    end

    def cmd_restart(_args, _o)
      ms = app.machines
      raise Error.new("#{app.name} has no machines", next_steps: ["flk deploy"]) if ms.empty?
      ms.each { restart_machine(_1) }
      next_step("flk status", "flk logs")
    end
    def machine_destroy(args, o) = Util.with_lock { each_ref(args) { |m| destroy_machine(m, force: o[:force]) } }
    # Run by flk itself (VM.spawn_revive) when a machine exited on its own
    # and its restart policy wants it back: back off 1, 2, 4... up to 60s,
    # then boot, until `retries` restarts in a row. A run of 10+ minutes
    # resets the count.
    def machine_revive(args, _o)
      a = App.new(@app_name || raise(Error, "revive needs -a APP"))
      return unless a.exists?
      m = a.machines.find { _1.id == args[0] } or return
      policy = m.restart_policy
      started = (Time.parse(m.h["started_at"]) rescue Time.now)
      count = Time.now - started > 600 ? 0 : m.h.dig("restarts", "count").to_i
      status = m.last_exit_status
      note = ->(s) { File.open(m.path("console.log"), "a") { _1.puts "\n--- flk: #{s} (#{Util.now}) ---" } }
      if count >= policy["retries"]
        note["restart policy #{policy['policy']}: gave up after #{count} restarts in a row (last exit status #{status || 'none'})"]
        m.h["restarts"] = { "count" => count, "gave_up_at" => Util.now }
        Events.machine("machine.gave_up", m, "after #{count} restarts in a row (last exit status #{status || 'none'})")
        return m.save!
      end
      sleep [2**count, 60].min
      m = a.machines.find { _1.id == args[0] } or return # reload: someone may have acted meanwhile
      return if m.running? || m.desired_state != "started" || m.stopping?
      note["restart policy #{policy['policy']}: exit status #{status || 'none'}, restart #{count + 1} of #{policy['retries']}"]
      m.h["restarts"] = { "count" => count + 1, "last_at" => Util.now }
      boot(m, "Machine #{m.id} [#{m.name}] restarted by its restart policy", revive: true)
    rescue AlreadyRunning
      nil # flk resume (or a user) started it after the check above
    end

    def machine_stats(args, o)
      reap_exited
      ms = if o[:all]
             raise Error, "--all takes no IDs (it's every machine)" if args.any?
             App.all.flat_map(&:machines)
           else
             args.empty? ? app.machines : args.map { app.machine!(_1) }
           end
      stats = VM.stats(ms)
      return puts(JSON.pretty_generate(stats)) if o[:json]
      return puts("No machines") if stats.empty?
      Util.table(%w[APP ID NAME STATE CPU RSS MEMORY UPTIME], stats.map do |s|
        [s["app"], s["id"], s["name"], s["state"], s["cpu_percent"] ? "#{s['cpu_percent']}%" : "-",
         s["rss_mb"] ? "#{s['rss_mb']}MB" : "-", "#{s['memory_mb']}MB", s["uptime_s"] ? duration(s["uptime_s"]) : "-"]
      end)
    end

    def duration(s)
      return "#{s}s" if s < 60
      return "#{s / 60}m" if s < 3600
      return "#{s / 3600}h#{(s % 3600) / 60}m" if s < 86_400
      "#{s / 86_400}d#{(s % 86_400) / 3600}h"
    end

    def machine_status(args, _o) = print_json_each(args) { |m| m.h.merge("state" => m.state) }
    def machine_config(args, _o) = print_json_each(args) { |m| VM.spec(m) }

    # One ID: an object. Several: one array, so the output is always one JSON document.
    def print_json_each(refs)
      docs = refs.map { yield app.machine!(_1) }
      puts JSON.pretty_generate(docs.size == 1 ? docs.first : docs)
    end

    def each_ref(argv, &blk) = argv.map { app.machine!(_1) }.each(&blk)

    def scale_count(args, _o)
      raise Error, "N must be a whole number (got '#{args[0]}')" unless args[0].match?(/\A\d+\z/)
      n = args[0].to_i
      a = app
      Util.with_lock do
        # Record the new scale only once it's known to fit: a refused scale
        # must not make the next deploy try it again.
        save_scale = -> { meta = a.meta; meta["scale"] = n; a.save_meta(meta) }
        rel = a.current_release
        unless rel
          save_scale.call
          next puts("Scale set to #{n}; applies on first deploy")
        end

        ms = a.machines
        if n > ms.size
          cfg = config_for(a.name)
          base = cfg ? cfg.machine_config : ms.last&.config&.reject { |k, _| k == "mounts" }
          raise Error, "run from the app directory so flk can read its config" unless base
          check_capacity!(a, base, creating: n - ms.size)
          save_scale.call
          (n - ms.size).times { create_machine(a, rel, base) }
        else
          save_scale.call
          ms.last(ms.size - n).reverse_each { destroy_machine(_1, force: true) }
        end
        puts "Scaled #{a.name} to #{n} machine#{'s' unless n == 1}"
        next_step("flk status")
      end
    end

    def create_machine(a, rel, mconfig)
      i = Net.allocate!
      id = SecureRandom.hex(7)
      h = {
        "id" => id, "name" => Machine.generate_name, "app" => a.name,
        "tap_index" => i, "ip" => Net.ip(i), "mac" => Net.mac(i), "release" => rel["version"],
        "config" => mconfig.merge("mounts" => attach_volumes(a, id, mconfig["mount_specs"])),
        "created_at" => Util.now
      }
      m = Machine.new(a, h)
      FileUtils.mkdir_p(m.dir)
      m.save!
      install_rootfs(m, rel)
      own_new_volumes(m, rel)
      boot(m, "Machine #{m.id} [#{m.name}] created", event: "machine.created")
    end

    # The block runs while the machine is stopped (before_deploy backups).
    def update_machine(m, rel, mconfig)
      puts "  #{m.id} [#{m.name}] stopping" if m.running?
      VM.stop(m)
      yield if block_given?
      m.h["release"] = rel["version"]
      m.h["config"] = mconfig.merge("mounts" => attach_volumes(m.app, m.id, mconfig["mount_specs"]))
      m.save!
      install_rootfs(m, rel)
      own_new_volumes(m, rel)
      boot(m, "Machine #{m.id} [#{m.name}] updated to v#{rel['version']}", event: "machine.updated")
    end

    # Root filesystem is ephemeral per release, exactly like Fly:
    # persistent data belongs on a volume.
    def install_rootfs(m, rel)
      raise Error, "release image missing: #{rel['path']} (redeploy)" unless File.exist?(rel["path"])
      Util.run!("cp", "--reflink=auto", "--sparse=always", rel["path"], m.path("rootfs.ext4"))
    end

    # A volume from `volumes create` without --owner or --from-dir is an
    # empty ext4 owned by root. The first time a machine uses it, its root
    # takes the owner of the mount point in the release image, so a
    # Dockerfile's `chown app /data` still holds with the volume over /data;
    # with no such mount point (or a root-owned one) and a non-root USER,
    # that user's (../valheim.flk BUGS.flk.md #4: vh-run, as ubuntu, couldn't
    # write /data). The flag stays while nothing was decided and the volume
    # is still empty, so a fixed image applies at the next deploy; a volume
    # with data in it is never re-owned.
    def own_new_volumes(m, rel)
      vols = m.app.volumes
      todo = Array(m.config["mounts"]).filter_map do |mt|
        v = vols.find { _1["id"] == mt["volume"] }
        [v, mt["destination"]] if v&.dig("owner_from_image")
      end
      return if todo.empty?
      user = nil
      todo.each do |v, dest|
        unless (VolFS.list(v["path"], "/").map(&:name) - ["lost+found"]).empty?
          v.delete("owner_from_image")
          next
        end
        e = VolFS.stat(rel["path"], dest)
        user ||= image_user(rel["path"])
        uid, gid, why =
          if e&.dir? && [e.uid, e.gid] != [0, 0] then [e.uid, e.gid, "like #{dest} in the image"]
          elsif user[:uid]&.positive?
            [user[:uid], user[:gid], "the image's USER #{user[:name]}; #{dest} #{e ? "is root's" : "isn't"} in the image"]
          end
        if uid
          VolFS.batch!(v["path"], VolFS.owner_cmds("/", uid, gid))
          VolFS.fsck!(v["path"])
          puts "  volume #{v['name']}: root now owned by #{uid}:#{gid} (#{why})"
          v.delete("owner_from_image")
        elsif !user[:root]
          warn Util.yellow("  ⚠ volume #{v['name']} stays owned by root, but the app runs as #{user[:name]}, which isn't " \
                           "in the image's /etc/passwd: add `RUN install -d -o USER -g GROUP #{dest}` to the Dockerfile, " \
                           "or with the machine stopped: flk files chown UID:GID #{v['name']}:/")
        end
      end
      m.app.save_volumes(vols)
    end

    # Who the release's app runs as (its image's USER, as /flk/init reads
    # it): { name:, uid:, gid:, root: }; uid nil when a name can't be found
    # in the image's /etc/passwd. Like init: no group means the passwd
    # entry's, or for a numeric user without one, the same number.
    def image_user(img)
      u = (VolFS.read(img, "/flk/user").strip rescue "")
      return { name: "root", uid: 0, gid: 0, root: true } if ["", "root", "0", "0:0"].include?(u)
      usr, grp = u.split(":", 2)
      table = lambda do |file|
        (VolFS.read(img, file) rescue "").lines.map { _1.chomp.split(":") }
      end
      pw = table.call("/etc/passwd").find { usr.match?(/\A\d+\z/) ? _1[2] == usr : _1[0] == usr }
      uid = usr.match?(/\A\d+\z/) ? usr.to_i : pw&.[](2)&.to_i
      gid = if grp.nil? then pw ? pw[3].to_i : uid
            elsif grp.match?(/\A\d+\z/) then grp.to_i
            else table.call("/etc/group").find { _1[0] == grp }&.[](2)&.to_i
            end
      uid = nil if gid.nil?
      { name: u, uid: uid, gid: gid, root: uid&.zero? || false }
    end

    # A volume attaches to exactly one machine. Prefer the one this machine
    # already had, so redeploys never swap data between machines.
    def attach_volumes(a, mid, specs)
      return [] if specs.empty?
      vols = a.volumes
      prev = vols.select { _1["attached_machine"] == mid }.map { _1["id"] }
      vols.each { _1["attached_machine"] = nil if _1["attached_machine"] == mid }
      out = specs.map do |s|
        v = vols.find { _1["name"] == s["source"] && prev.include?(_1["id"]) && _1["attached_machine"].nil? } ||
            vols.find { _1["name"] == s["source"] && _1["attached_machine"].nil? } or
          raise Error, "no unattached volume named '#{s['source']}'; create one: flk volumes create #{s['source']} --size 1"
        v["attached_machine"] = mid
        { "volume" => v["id"], "destination" => s["destination"] }
      end
      a.save_volumes(vols)
      out
    end

    def destroy_machine(m, force: false)
      raise Error, "machine #{m.id} is running; stop it or pass --force" if m.running? && !force
      VM.stop(m)
      vols = m.app.volumes
      vols.each { _1["attached_machine"] = nil if _1["attached_machine"] == m.id }
      m.app.save_volumes(vols)
      FileUtils.rm_rf(m.dir)
      Events.machine("machine.destroyed", m)
      puts "Machine #{m.id} [#{m.name}] destroyed"
    end

    # revive: a restart by the restart policy; anything else is a person
    # starting it, which resets the count of restarts in a row.
    def boot(m, msg, revive: false, event: "machine.started")
      m.h.delete("restarts") unless revive
      VM.start(m)
      Events.machine(revive ? "machine.restarted" : event, m, msg)
      puts "  #{Util.green('✔')} #{msg} (#{m.ip})"
      port = m.config["internal_port"] or return m
      if VM.wait_port(m, port, 30)
        puts "    listening on #{m.ip}:#{port}"
      else
        puts Util.yellow("    ⚠ nothing listening on #{m.ip}:#{port} after 30s; check: flk logs -i #{m.id}")
      end
      show_ports(m)
      m
    end

    def show_ports(m)
      Array(m.config["ports"]).product(Ports.binds(m)).each do |p, bind|
        key = "#{p['proto']}/#{p['port']}"
        label = bind ? "#{bind}:#{key}" : key
        o = Ports.owner(key, bind)
        if (why = Ports.blocked_reason(p["proto"], p["port"], bind: bind))
          puts Util.yellow("    ⚠ host port #{label} not forwarded: #{why}")
        elsif o.nil? || !Ports.available?
          next
        elsif o["machine"] == m.id
          puts "    host port #{label} -> #{m.ip}:#{p['internal_port']}  " \
               "(reach it at #{bind || Net.host_address || 'the host LAN IP'}:#{p['port']}, not 127.0.0.1)"
        else
          puts Util.yellow("    ⚠ host port #{label} is taken by #{o['app']} (#{o['machine']}); this machine gets it when that one stops")
        end
      end
    end
  end
end
