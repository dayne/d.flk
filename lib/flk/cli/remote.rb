module Flk
  # Running a command on the host an app lives on (Peer,
  # docs/remote-design.md).
  #
  # Which host: -H NAME, else FLK_HOST, else [flk] host in the app's
  # flk.toml, else the host this one last deployed -a APP to. "local" (-H
  # or FLK_HOST) means here, whatever flk.toml says.
  #
  # -H and FLK_HOST send any command. The host found through flk.toml only
  # sends commands about the app. What is about a host keeps acting on
  # this one (host_level?): the HOST_LEVEL commands, host settings (config
  # set/unset, --host) and anything over every app (--all).
  class CLI
    private

    NEVER_REMOTE = %w[help completion peers].freeze
    # Not sent on flk.toml's word alone: they are about a host, not an app.
    HOST_LEVEL = %w[setup doctor version resume stop-all disk images apps ports].freeze
    # Can't work from another host: root, a listener or a mount on this one.
    REMOTE_REFUSED = {
      "setup" => "it installs flk's files on the host it runs on: run it there",
      "proxy" => "it would listen on the other host: reach the machine's port there, or use ssh -L",
      "ssh" => "its mounts and sockets are made on the host that runs the machine: run it there"
    }.freeze
    SYNCED = %w[launch deploy build].freeze    # send the app's directory first
    WANTS_STDIN = %w[secrets exec console].freeze

    # Sends the command to the app's host and returns true, or returns nil:
    # the command is for this host. Exits with the peer's status otherwise.
    def run_on_peer(argv)
      name = argv.first == "--version" ? "version" : argv.find { !_1.start_with?("-") }
      return nil if name.nil? || NEVER_REMOTE.include?(name)
      host, explicit = target_host(name, argv)
      return nil unless host
      return nil if argv.intersect?(%w[-h --help]) # help is the same everywhere, and is here
      raise Error, "flk #{name} can't be sent to #{host}: #{REMOTE_REFUSED[name]}" if REMOTE_REFUSED[name]

      cfg = local_config
      app_name = @app_name || cfg&.app
      warn "flk: on #{host}#{" ([flk] host in #{File.basename(cfg.path)})" if !explicit && cfg&.host == host}" if $stderr.tty?

      dir = env = nil
      if SYNCED.include?(name)
        cfg = config_to_send(name, host, argv) || cfg
        dir, env = send_source(host, cfg)
      end
      remote_argv = [*(["-a", @app_name] if @app_name), *argv]
      # status, logs... in the app's directory here mean that app there
      remote_argv = ["-a", app_name, *argv] if !@app_name && app_name && !dir && !host_level?(name, argv)

      code = Peer.run(host, remote_argv, dir: dir, env: env || {}, stdin: WANTS_STDIN.include?(name))
      if code == Peer::SSH_FAILED
        warn "#{Util.red('Error:')} flk #{name} didn't run: no ssh connection to #{host} (#{[*Peer.ssh, Peer.dest(host)].join(' ')})"
        warn "Next: flk peers   or, to act on this host: flk -H local #{argv.join(' ')}"
      end
      remember_peer_app(name, argv, host, cfg, code)
      exit code unless code.zero?
      true
    end

    # [host, explicit]: explicit when -H or FLK_HOST named it.
    def target_host(cmd_name, argv)
      named = @host_name || ENV["FLK_HOST"].to_s
      unless named.empty?
        return nil if named == Peer::LOCAL
        Peer.check_name!(named, @host_name ? "-H" : "FLK_HOST")
        return named == Peer.self_name ? nil : [named, true]
      end
      return nil if host_level?(cmd_name, argv)
      host = implied_host
      return nil if host.nil? || host == Peer.self_name
      if ENV["FLK_HOP"]
        raise Error, "this app's flk.toml says it runs on '#{host}', and this host, reached as that one, is called " \
                     "'#{Peer.self_name}': set name = \"#{host}\" in #{Host::PATH} here, or correct [flk] host"
      end
      [host, false]
    end

    # About a host, not about the app in this directory: flk.toml's word
    # doesn't send it anywhere. (`config set` writes host.toml; --host and
    # --all are `config show`'s, `check`'s, `events`' and `context`'s.)
    def host_level?(cmd_name, argv)
      HOST_LEVEL.include?(cmd_name) || argv.include?("--host") || argv.include?("--all") ||
        (cmd_name == "config" && argv.intersect?(%w[set unset]))
    end

    # The host an app is said to run on: flk.toml here, or the record of
    # where this host deployed -a APP to. An app that exists here is here.
    def implied_host
      cfg = local_config
      return cfg.host if cfg && (@app_name.nil? || cfg.app == @app_name)
      return nil unless @app_name
      return nil if File.directory?(File.join(ROOT, "apps", @app_name))
      Peer.remote_apps.dig(@app_name, "host")
    end

    # flk.toml in this directory, if it parses (a broken one is reported by
    # the command itself, on this host).
    def local_config
      return @local_config if defined?(@local_config)
      @local_config = begin
        AppConfig.find
      rescue Error
        nil
      end
    end

    # The config whose directory goes to the peer: the one here, or for -a
    # APP from another directory the one recorded at its last deploy.
    def config_to_send(name, host, argv)
      cfg = local_config
      return cfg if cfg && (@app_name.nil? || cfg.app == @app_name)
      if @app_name
        path = Peer.remote_apps.dig(@app_name, "config_path")
        return AppConfig.new(path) if path && File.exist?(path)
        raise Error, "flk doesn't know where #{@app_name}'s directory is on this host: run flk #{name} in it"
      end
      raise Error, "no flk.toml or fly.toml in #{Dir.pwd} to send to #{host}" unless name == "launch"
      new_config_for(host, argv)
    end

    # `flk -H PEER launch` in a directory without a config: write it here
    # (this is where the app is developed), naming the host.
    def new_config_for(host, argv)
      o = parse_opts(Commands.find("launch"), argv.dup.tap { _1.delete("launch") }) || {}
      name = o[:name] || File.basename(Dir.pwd).downcase.gsub(/[^a-z0-9-]+/, "-").gsub(/\A-+|-+\z/, "")[0, 63]
      App.new(name) # validates
      File.write("flk.toml", default_toml(name, o, host: host))
      puts "Created flk.toml (it runs on #{host}: [flk] host)"
      @local_config = AppConfig.find
    end

    # Copies the config's directory to the peer; returns where it is there
    # and the environment the peer's flk needs.
    def send_source(host, cfg)
      cfg.app
      cfg.host # a bad value fails here, before anything is sent
      hi = Peer.hello(host)
      if hi["version"] != VERSION
        warn Util.yellow("flk here is #{VERSION}, on #{host} #{hi['version']}: a flk.toml key or option the older one lacks won't work")
      end
      if cfg.host && cfg.host != hi["host"]
        raise Error, "#{File.basename(cfg.path)} says the app runs on '#{cfg.host}', but that host calls itself '#{hi['host']}': " \
                     "use that name for [flk] host (host.toml [peers] here can map it to an ssh destination), " \
                     "or set name = \"#{cfg.host}\" in host.toml there"
      end
      origin = Peer.origin(cfg.dir)
      remote = Peer.src_dir(hi.fetch("root"), cfg.app)
      puts "==> Sending #{cfg.dir} to #{host}:#{remote}"
      Peer.sync(host, cfg.dir, remote)
      [remote, { "FLK_ORIGIN" => JSON.generate(origin) }]
    end

    # After a launch or deploy there, -a APP finds the host from anywhere
    # on this one; after apps destroy there, it no longer does.
    def remember_peer_app(name, argv, host, cfg, code)
      if %w[launch deploy].include?(name) && cfg && code.zero?
        Peer.record_app(cfg.app, host, File.expand_path(cfg.path))
      elsif name == "apps" && argv.include?("destroy") && code.zero?
        (argv - %w[apps destroy]).reject { _1.start_with?("-") }.each { Peer.forget_app(_1) }
      end
    end

    # The marker left in a directory that was sent here: where it is from.
    def note_origin(cfg)
      o = Peer.origin_from_env or return nil
      File.write(File.join(cfg.dir, Peer::MARKER),
                 "This directory is a copy flk sent from #{o['host']}:#{o['path']} at #{Util.now}.\n" \
                 "Edit it there: the next flk deploy from #{o['host']} replaces what is here.\n")
      o
    rescue SystemCallError
      o
    end
  end
end
