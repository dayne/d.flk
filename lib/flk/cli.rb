require "optparse"

module Flk
  class CLI
    def self.start(argv) = new.run(argv)

    def run(argv)
      argv = extract_global(argv)
      name = argv.shift
      case name
      when nil, "-h", "--help" then return puts(Commands.short_help)
      when "--version" then return cmd_version([], {})
      end
      cmd = Commands.find(name) or
        raise Error, "unknown command '#{name}'#{hint_for(Commands.suggest(name))} (see: flk help)"
      sub = pick_sub(cmd, argv)
      @help_ref = ["flk help", cmd[:name], sub&.dig(:name)].compact.join(" ")
      entry = sub || cmd
      if cmd[:subs] && !sub
        return puts(Commands.command_help(cmd)) if argv.intersect?(%w[-h --help])
        raise Error, "flk #{cmd[:name]} needs a subcommand: #{cmd[:subs].map { _1[:name] }.join(', ')} (see: flk help #{cmd[:name]})"
      end

      opts = parse_opts(entry, argv) or return puts(Commands.command_help(cmd, sub))
      min, max = Commands.arity(entry[:args])
      if argv.size < min || (max && argv.size > max)
        what = argv.size < min ? "missing arguments" : "unexpected argument '#{argv[max]}'"
        raise Error, "#{what}; usage: #{Commands.usage(cmd, sub)}"
      end
      send(Commands.handler(cmd, sub), argv, opts)
    rescue Error, OptionParser::ParseError => e
      msg = e.message.sub(/\n\s*Did you mean\?\s*(\S+).*/m) { "; did you mean --#{$1}?" }
      # Some Rubies leave the suggestion out under require_exact (parse_opts)
      msg += "; did you mean #{@option_hint}?" if @option_hint && !msg.include?("did you mean")
      ref = @help_ref && e.is_a?(OptionParser::ParseError) ? " (see: #{@help_ref})" : ""
      warn "#{Util.red('Error:')} #{msg}#{ref}"
      warn "Next: #{e.next_steps.join('   or: ')}" if e.is_a?(Error) && e.next_steps
      exit 1
    rescue Interrupt
      exit 130
    end

    private

    def hint_for(word) = word ? "; did you mean '#{word}'?" : ""

    # The last line of a command that changed something.
    def next_step(*cmds) = puts("Next: #{cmds.join('   or: ')}")

    # The subcommand named by argv.first, or the default one. Options
    # (-x) before a subcommand, like `flk machine --help`, mean "none given".
    def pick_sub(cmd, argv)
      return nil unless cmd[:subs]
      word = argv.first
      if word && !word.start_with?("-")
        sub = Commands.find(word, cmd[:subs]) or
          raise Error, "unknown subcommand 'flk #{cmd[:name]} #{word}'#{hint_for(Commands.suggest(word, cmd[:subs]))} (see: flk help #{cmd[:name]})"
        argv.shift
        return sub
      end
      return nil if argv.intersect?(%w[-h --help])
      cmd[:default_sub] && Commands.find(cmd[:default_sub], cmd[:subs])
    end

    # Options from the command table; anything else is an error. Returns nil
    # for --help. Positionals stay in argv.
    # Everything after "--" is positional (split off here: optparse with
    # require_exact trips over short options past "--"). Commands with
    # passthrough (exec) stop at their first positional, so the command's
    # own options aren't taken for flk's.
    def parse_opts(entry, argv)
      opts = {}
      help = false
      tail = (i = argv.index("--")) ? argv.slice!(i..)[1..] : []
      long_switches = Array(entry[:opts]).flat_map { Commands.switches(_1) }
                                         .select { _1.start_with?("--") }
                                         .map { _1[/\A(--[\w-]+)/, 1] }
                                         .compact
      parser = OptionParser.new do |p|
        p.require_exact = true # no --jso for --json: typos are errors, not guesses
        Array(entry[:opts]).each do |o|
          # a flag is true when given; OptionParser hands "--no-x" flags false
          flag = Commands.switches(o).none? { _1.match?(/[ =]/) }
          p.on(*o) { |v| opts[Commands.key(o)] = flag || v }
        end
        p.on("-h", "--help") { help = true }
      end
      begin
        entry[:passthrough] ? parser.order!(argv) : parser.parse!(argv)
      rescue OptionParser::InvalidOption => e
        # require_exact suppresses DidYouMean; carry the hint to the top-level rescue
        bad = e.args.first.to_s
        @option_hint = DidYouMean::SpellChecker.new(dictionary: long_switches).correct(bad).first
        raise
      end
      argv.concat(tail)
      help ? nil : opts
    end

    def extract_global(argv)
      out = []
      it = argv.each
      loop do
        a = it.next
        if a == "--" # the rest is positional, -a included
          out << a
          loop { out << it.next }
          break
        end
        case a
        when "-a", "--app" then @app_name = it.next
        when /\A--app=(.+)\z/ then @app_name = $1
        else out << a
        end
      end
      out
    end

    # ./flk.toml (or fly.toml), unless -a names another app: then the file
    # flk recorded for it at launch/deploy, so -a works from anywhere.
    def config
      @config ||= begin
        here = AppConfig.find
        if @app_name && here&.app != @app_name
          recorded_config(@app_name)
        else
          here || raise(Error, "no flk.toml or fly.toml in #{Dir.pwd} (run: flk launch)")
        end
      end
    end

    def recorded_config(name)
      a = App.new(name)
      path = a.exists? ? a.meta["config_path"] : nil
      unless path
        raise Error, "flk doesn't know where #{name}'s flk.toml is yet; run flk deploy (or flk launch --no-deploy) " \
                     "once in its directory"
      end
      raise Error, "#{name}'s config was at #{path}, which is gone; run flk deploy in its new directory" unless File.exist?(path)
      cfg = AppConfig.new(path)
      raise Error, "#{path} now belongs to app '#{cfg.app}', not #{name}" unless cfg.app == name
      cfg
    end

    # The config for an app if flk can find it (here, or recorded), else nil.
    def config_for(name)
      here = (AppConfig.find rescue nil)
      return here if here&.app == name
      recorded_config(name)
    rescue Error
      nil
    end

    # Remember where the config lives (launch, deploy).
    def record_config_path(a, cfg)
      meta = a.meta
      return if meta["config_path"] == File.expand_path(cfg.path)
      meta["config_path"] = File.expand_path(cfg.path)
      a.save_meta(meta)
    end

    def app
      @app ||= begin
        name = @app_name || AppConfig.find&.app ||
               raise(Error, "no app: pass -a APP or run inside a directory with flk.toml/fly.toml")
        a = App.new(name)
        raise Error, "app '#{name}' not found (run: flk launch, or flk launch --no-deploy to register it without deploying)" unless a.exists?
        a
      end
    end

    # Every listing command tidies machines that exited on their own, so the
    # host port map follows them (ports are global, hence all apps).
    def reap_exited(wait: false) = VM.reap(App.all.flat_map(&:machines), wait: wait)
  end
end
