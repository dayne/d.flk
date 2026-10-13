module Flk
  # Every command, described once. The CLI parses arguments from this table
  # (unknown options and extra arguments are errors), and all help output is
  # generated from it: `flk help`, `flk help CMD`, `flk CMD --help`,
  # `flk help --all` (Markdown reference) and `flk help --all --json`.
  #
  # Entry keys:
  #   name, aliases  how it's typed
  #   group          heading in `flk help`
  #   args           positionals: NAME required, [NAME] optional, NAME... one or more
  #   summary        one line
  #   opts           OptionParser#on arguments; the long switch names the key
  #                  ("--no-tail" -> :no_tail)
  #   notes          details for `flk help CMD` and the reference
  #   json           has --json output
  #   blocks         runs until interrupted (why, and what to do instead)
  #   subs           subcommands (same keys); default_sub runs when none given
  #   run            handler method; default cmd_NAME, or NAME_SUB for subs
  #   hidden         left out of the short `flk help`
  module Commands
    JSON_OPT = ["--json", "Print JSON instead of a table"].freeze
    BACKUP_TO_OPT = ["--to DIR", "Backup dir (default: backup_dir in ~/.config/flk/host.toml)"].freeze

    CONSOLE_OPTS = [["--send TEXT", "Type one line into the app's stdin, then return (no terminal needed)"],
                    ["--wait-log REGEX", "With --send: print console output until a line matches REGEX"],
                    ["--timeout SECONDS", Integer, "With --wait-log: give up after this long (default 10)"]].freeze

    GROUPS = ["Start here", "Setup", "Host", "Apps", "Machines", "Config & data"].freeze

    # `flk help TOPIC`: share/help/TOPIC.md, also appended to `flk help --all`
    TOPICS = {
      "cheatsheet" => "One screen: the commands you need, by task",
      "install" => "Setting up a host, from nothing to `flk doctor` passing",
      "first-app" => "Launch, configure, deploy and check an app",
      "operate" => "Day to day: changes, logs, consoles, reboots, disk, updates",
      "troubleshoot" => "Symptom -> cause -> command",
      "uninstall" => "Removing apps, host setup and files"
    }.freeze

    LIST = [
      { name: "context", group: "Start here",
        opts: [["--all", "Every app on this host, not just the current one"], ["--json", "Print JSON"],
               ["--no-host", "Skip the host checks (flk doctor): cheap enough to poll; host is just lan_ip"]], json: true,
        summary: "What flk sees right now: host health, the current app, machines, ports, next steps",
        notes: ["Run this first. It resolves the app the same way other commands do (-a APP, or flk.toml / fly.toml in the current directory) and works even when there is none.",
                "Also tidies machines that exited on their own, like status does."] },
      { name: "help", group: "Start here", args: "[COMMAND|TOPIC] [SUBCOMMAND]",
        opts: [["--all", "The full reference: concepts, every command, config, workflows, gotchas"],
               ["--json", "With --all: the command table as JSON"]],
        summary: "Show help for flk, a command, or a topic (cheatsheet, install, first-app, operate, troubleshoot, uninstall)",
        notes: ["`flk COMMAND --help` is the same as `flk help COMMAND`."] },
      { name: "completion", group: "Start here", args: "SHELL",
        summary: "Print a tab-completion script (bash; zsh via bashcompinit)",
        notes: ["Install: echo 'source <(flk completion bash)' >> ~/.bashrc  (or, with bash-completion loaded: flk completion bash > ~/.local/share/bash-completion/completions/flk)",
                "zsh: autoload -U bashcompinit && bashcompinit && source <(flk completion bash)"] },

      { name: "setup", group: "Setup",
        summary: "Download firecracker + guest kernel (no root), then run doctor",
        notes: ["Root setup (bridge, taps, NAT, port helper) is separate: sudo #{SETUP_HOST}"] },
      { name: "doctor", group: "Setup", opts: [JSON_OPT], json: true,
        summary: "Check host readiness",
        notes: ['--json prints {"schema", "ok", "checks": [{"label", "status", "hint"}], "services": [...]}; status is pass, fail or warn. warn means flk works but an optional feature (port forwarding) is off; ok is false only when a check fails.',
                'services: flk-net.service and flk-machines.service as systemd sees them: {"unit", "installed", "enabled", "active", "sub", "result", "since"}.'] },
      { name: "version", group: "Setup", summary: "Print the flk version" },

      { name: "resume", group: "Host",
        summary: "Start every machine that should be running (after a reboot, or after stop-all)",
        notes: ["Should be running: started, restarted, deployed or scaled, and not stopped with `flk machine stop` since. A machine whose app exited counts too.",
                "flk-machines.service runs it at boot (sudo #{SETUP_HOST} --install-service).",
                "-a APP limits it to one app."] },
      { name: "stop-all", group: "Host",
        summary: "Gracefully stop every running machine, remembering to resume them",
        notes: ["What the host does at shutdown (flk-machines.service): all machines stop in parallel, each with its kill_timeout, and `flk resume` brings them back.",
                "To stop a machine for good, use `flk machine stop`.",
                "-a APP limits it to one app."] },

      { name: "launch", group: "Apps",
        opts: [["--name NAME", "App name (default: directory name)"],
               ["--image IMAGE", "Use a prebuilt image instead of a Dockerfile"],
               ["--port PORT", Integer, "internal_port in the generated flk.toml (default 8080)"],
               ["--cpus N", Integer, "vCPUs in the generated flk.toml (default 1)"],
               ["--memory MB", Integer, "Memory in the generated flk.toml (default 256)"],
               ["--no-deploy", "Register the app but don't deploy"]],
        summary: "Create flk.toml (if missing) in the current directory, register the app, deploy",
        notes: ["An existing flk.toml or fly.toml is used as-is; the options only shape a new one.",
                "Deploys right away unless --no-deploy, or there's no Dockerfile / [build] image yet."] },
      { name: "deploy", group: "Apps",
        opts: [["--image IMAGE", "Deploy this image instead of building"],
               ["--no-rollback", "Leave a machine that fails its health checks on the new release (to debug it)"]],
        summary: "Build the image and roll machines to a new release",
        notes: ["Reads flk.toml / fly.toml in the current directory, or with -a APP the file flk recorded at the app's last launch/deploy, so it works from anywhere.",
                "Creates machines on the first deploy (count from `flk scale count`, default 1); later deploys stop, update and reboot each machine in turn.",
                "With health checks ([checks], services tcp_checks/http_checks, http_service checks; type tcp, http, or flk's log), each machine must pass them before the next is updated. One that fails goes back to its previous release, the release is marked failed, and the deploy stops (exit 1).",
                "Without checks it waits up to 30s per machine for internal_port to accept connections, then warns but carries on.",
                "Warns about flk.toml keys it doesn't know (typos).",
                "Volumes named in [[mounts]] must exist first: flk volumes create NAME --size 1 (one per machine)."] },
      { name: "status", group: "Apps", opts: [JSON_OPT], json: true,
        summary: "App and machine overview",
        notes: ["Also tidies machines that exited on their own and hands their host ports on."] },
      { name: "releases", group: "Apps", default_sub: "list", summary: "Release history, and rollback",
        subs: [
          { name: "list", aliases: %w[ls], opts: [JSON_OPT], json: true,
            summary: "Releases, newest first: current, failed (and why), kept for rollback, or pruned" },
          { name: "rollback", args: "[VERSION]",
            opts: [["--no-rollback", "If the old release fails its health checks, leave the machine on it"]],
            summary: "Roll machines back to an older release's image and config (default: the one before the current)",
            notes: ["Makes a new release (vN+1) from the old one, without building, and rolls it out like a deploy, health checks included.",
                    "If deploy --no-rollback left machines on a failed release, the default is the current (last good) release instead.",
                    "Only releases whose image is still kept can be used: the last two by default ([flk] keep_releases = N keeps more).",
                    "Volumes aren't touched: restore data with flk volumes restore."] }
        ] },
      { name: "disk", group: "Host", opts: [JSON_OPT], json: true,
        summary: "Disk space flk uses, per app: release images, machine disks, volumes, logs; and backups",
        notes: ["Sizes are allocated bytes (sparse files count only what they use); --json also gives apparent sizes.",
                "External volumes (--path / import) are counted apart: they're on other disks."] },
      { name: "images", group: "Host", opts: [JSON_OPT], json: true,
        summary: "flk's container images (flk.local/APP:vN): size, whether a machine runs that release, orphans",
        notes: ["Read-only. Images of destroyed apps (orphan) go with flk apps prune; deploys keep the last two per app."] },
      { name: "apps", group: "Apps", default_sub: "list", summary: "List or destroy apps",
        subs: [
          { name: "list", aliases: %w[ls], opts: [JSON_OPT], json: true, summary: "All apps on this host" },
          { name: "destroy", args: "NAME", opts: [["-y", "--yes", "Don't ask for confirmation"]],
            summary: "Destroy an app, its machines and volumes",
            notes: ["Without a terminal (agents, scripts) --yes is required; otherwise it asks."] },
          { name: "prune", summary: "Remove container images left behind by apps that no longer exist" }
        ] },
      { name: "config", group: "Apps", default_sub: "show", summary: "Inspect the app config",
        subs: [{ name: "show", opts: [["--json", "Accepted; the output is always JSON"]], json: true,
                 summary: "Print the parsed flk.toml / fly.toml and the machine config flk derives from it" }] },

      { name: "machine", aliases: %w[machines m], group: "Machines", default_sub: "list",
        summary: "Manage machines (IDs accept a prefix or the machine name)",
        subs: [
          { name: "list", aliases: %w[ls], opts: [JSON_OPT], json: true, summary: "Machines of the app" },
          { name: "start", args: "ID...", summary: "Boot machines" },
          { name: "stop", args: "ID...", summary: "Stop machines gracefully (SIGTERM to the app, kill after kill_timeout); they stay stopped across reboots" },
          { name: "restart", args: "ID...", summary: "Stop, then boot" },
          { name: "destroy", aliases: %w[rm], args: "ID...", opts: [["-f", "--force", "Stop it first if running"]],
            summary: "Delete machines (their volumes are kept, unattached)" },
          { name: "revive", args: "ID", hidden: true,
            summary: "Restart a machine that exited on its own, per its restart policy (run by flk itself)" },
          { name: "stats", args: "[ID...]", opts: [["--all", "Every app's machines (no -a needed)"], JSON_OPT], json: true,
            summary: "CPU and memory use of machines (default: all of the app's)",
            notes: ["cpu_percent is over a 0.5s sample; 100 means one host CPU. rss_mb is what the VM really uses of its memory_mb."] },
          { name: "status", aliases: %w[show], args: "ID...", opts: [["--json", "Accepted; the output is always JSON"]], json: true,
            summary: "Machine record and state as JSON (an array when given several IDs)" },
          { name: "config", args: "ID...", opts: [["--json", "Accepted; the output is always JSON"]], json: true,
            summary: "The Firecracker VM config as JSON (an array when given several IDs)" }
        ] },
      { name: "scale", group: "Machines", summary: "Set the number of machines",
        subs: [{ name: "count", args: "N", summary: "Create or destroy machines to reach N",
                 notes: ["Each new machine needs its own unattached volume per [[mounts]] entry.",
                         "Before the first deploy this just records N."] }] },
      { name: "logs", group: "Machines",
        opts: [["-i", "--instance ID", "One machine (default: all)"],
               ["-n", "--lines N", Integer, "Lines of history (default 50)"],
               ["-f", "--follow", "Keep following, even without a terminal"],
               ["--no-tail", "Print and exit, even in a terminal"]],
        summary: "Serial console output (app stdout/stderr and boot messages)",
        notes: ["Follows new output only when stdout is a terminal; piped or run by an agent it prints the last lines and exits.",
                "Each machine keeps console.log, rotated to console.log.1 past FLK_LOG_MAX_MB (default 10) MB."] },
      { name: "console", group: "Machines", args: "[ID]", opts: CONSOLE_OPTS,
        blocks: "attaches an interactive terminal; agents: use --send (and --wait-log), or `flk logs`",
        summary: "Attach to a machine's serial console, or --send one line to the app's stdin",
        notes: ["Detach with Ctrl-b d (Ctrl-b Ctrl-b d inside tmux). Attaching needs a terminal; --send doesn't.",
                "--send types TEXT and Enter into the app's stdin (needs [flk] stdin = \"console\", the default). " \
                "With --wait-log it then prints the console output until a line matches REGEX (exit 1 after --timeout). " \
                "The console echoes what you type; that echo is skipped when matching.",
                "It's the serial console, not a shell: you see app output and type to its stdin (server consoles: stop, say, op...). Ctrl-C here doesn't signal the app; use flk machine stop.",
                "`flk ssh console` is an alias."] },
      { name: "ssh", group: "Machines", hidden: true, summary: "Alias: `flk ssh console` = `flk console`",
        subs: [{ name: "console", args: "[ID]", run: :cmd_console, summary: "Same as flk console", opts: CONSOLE_OPTS,
                 blocks: "attaches an interactive terminal; agents: use --send (and --wait-log), or `flk logs`" }] },
      { name: "proxy", group: "Machines", args: "LOCAL[:REMOTE] [ID]",
        opts: [["--bind ADDR", "Listen address (default 127.0.0.1; 0.0.0.0 exposes it on the LAN)"]],
        blocks: "forwards until Ctrl-C; run it in the background (`flk proxy 8080 &`) and kill it when done",
        summary: "Forward a local TCP port to a machine",
        notes: ["Rarely needed: machine IPs (172.30.0.x, see `flk status`) are reachable from the host directly."] },
      { name: "ports", group: "Machines", default_sub: "list", summary: "Host ports forwarded to machines ([[services.ports]])",
        subs: [
          { name: "list", aliases: %w[ls], opts: [JSON_OPT], json: true,
            summary: "Forwarded ports: active, waiting (another machine has it) or blocked (and why)" },
          { name: "sync", summary: "Rewrite the host's port map from the running machines" },
          { name: "reap", hidden: true,
            summary: "Tidy machines that exited on their own and hand their ports on (run automatically by flk's tmux hook)" }
        ] },

      { name: "secrets", group: "Config & data", default_sub: "list",
        summary: "App secrets, delivered to machines as env vars",
        notes: ["Changing secrets restarts running machines unless --stage is given."],
        subs: [
          { name: "list", aliases: %w[ls], opts: [JSON_OPT], json: true, summary: "Names and digests (never values)" },
          { name: "set", args: "KEY=VALUE...", opts: [["--stage", "Don't restart machines; applies on next start/deploy"]],
            summary: "Set secrets (VALUE '-' reads it from stdin)" },
          { name: "unset", args: "KEY...", opts: [["--stage", "Don't restart machines; applies on next start/deploy"]],
            summary: "Remove secrets" },
          { name: "import", opts: [["--stage", "Don't restart machines; applies on next start/deploy"]],
            summary: "Set secrets from KEY=VALUE lines on stdin" }
        ] },
      { name: "volumes", aliases: %w[volume vol], group: "Config & data", default_sub: "list",
        summary: "Persistent disks (sparse ext4), one machine each",
        subs: [
          { name: "list", aliases: %w[ls], opts: [JSON_OPT], json: true, summary: "Volumes and what they're attached to" },
          { name: "create", args: "NAME",
            opts: [["-s", "--size GB", Integer, "Size in GB (default 1)"],
                   ["--path FILE", "Create the image at FILE (e.g. on a bigger disk) instead of flk's state dir; flk never deletes it"],
                   ["--from-dir DIR", "Fill it with a copy of DIR (owner/group IDs kept as-is)"]],
            summary: "Create a volume for [[mounts]] source = NAME" },
          { name: "import", args: "NAME", opts: [["--path FILE", "An existing ext4 image file (required)"]],
            summary: "Register an existing ext4 image as a volume; flk never deletes it",
            notes: ["Size comes from the file. Don't mount it on the host while a machine uses it."] },
          { name: "destroy", aliases: %w[rm], args: "ID|NAME",
            opts: [["--delete-data", "Also delete an external (--path / import) volume's file"]],
            summary: "Delete an unattached volume and its data (external volumes: unregister, keep the file)" },
          { name: "backup", args: "[ID|NAME...]",
            opts: [BACKUP_TO_OPT, ["--keep N", Integer, "Keep this many backups per volume (default: [flk.backup] keep, host backup_keep, 7)"],
                   ["--mode MODE", "stop, live or pause: override [flk.backup] mode"],
                   ["--no-check", "Skip the e2fsck of the copy"]],
            summary: "Copy volumes (default: all of the app's) to the backup dir, then prune old copies",
            notes: ["How the app is kept from writing comes from [flk.backup] in flk.toml (see flk help --all): " \
                    "by default its machine is stopped for the copy and started again; " \
                    "mode = \"live\" with pre/post hooks (e.g. save-off / save-on) copies while it runs.",
                    "Copies are sparse, and instant on XFS/btrfs when the backup dir shares the volume's filesystem. " \
                    "The copy is checked with e2fsck (a copy of a running machine gets its journal replayed)."] },
          { name: "backups", args: "[ID|NAME...]", opts: [BACKUP_TO_OPT, JSON_OPT], json: true,
            summary: "List a volume's backups (default: all of the app's volumes), newest first" },
          { name: "restore", args: "ID|NAME [BACKUP]", opts: [BACKUP_TO_OPT],
            summary: "Replace a volume's data with a backup (default: the latest); its machine must be stopped",
            notes: ["BACKUP is a file name from flk volumes backups, or part of it (e.g. its date). " \
                    "The current image is kept beside it as FILE.before-restore-TIME, not deleted."] },
          { name: "extend", args: "ID|NAME", opts: [["-s", "--size GB", Integer, "New size in GB (required; grow only)"]],
            summary: "Grow a volume and its filesystem; its machine must be stopped" }
        ] }
    ].freeze

    GLOBAL_OPTS = [["-a", "--app APP", "Act on this app instead of the one in ./flk.toml (any command)"]].freeze

    EXIT_CODES = { 0 => "success", 1 => "error (message on stderr, starting with 'Error:')", 130 => "interrupted (Ctrl-C)" }.freeze

    module_function

    def all = LIST

    def find(name, list = LIST)
      list.find { |c| c[:name] == name || Array(c[:aliases]).include?(name) }
    end

    # CLI method for a command: :run, else cmd_NAME or NAME_SUB ("stop-all" -> cmd_stop_all)
    def handler(cmd, sub = nil)
      (sub || cmd)[:run] || (sub ? "#{cmd[:name]}_#{sub[:name]}" : "cmd_#{cmd[:name]}").tr("-", "_")
    end

    def names(list = LIST) = list.flat_map { [_1[:name], *Array(_1[:aliases])] }

    def suggest(word, list = LIST)
      DidYouMean::SpellChecker.new(dictionary: names(list)).correct(word).first
    rescue NameError
      nil
    end

    def key(opt)
      long = opt.find { _1.is_a?(String) && _1.start_with?("--") } or
        raise ArgumentError, "option without a long switch: #{opt.inspect}"
      long[/\A--([\w-]+)/, 1].tr("-", "_").to_sym
    end

    def switches(opt) = opt.select { _1.is_a?(String) && _1.start_with?("-") }
    def desc(opt) = opt.reject { !_1.is_a?(String) || _1.start_with?("-") }.join(" ")

    # [min, max] positional count from an args string; max nil = unbounded
    def arity(args)
      toks = args.to_s.split
      min = toks.count { !_1.start_with?("[") }
      max = toks.any? { _1.end_with?("...") || _1.end_with?("...]") } ? nil : toks.size
      [min, max]
    end

    def usage(cmd, sub = nil)
      e = sub || cmd
      opts = Array(e[:opts]).map { "[#{switches(_1).last}]" }
      sub_word = sub ? sub[:name] : (cmd[:subs] && "SUBCOMMAND")
      ["flk", cmd[:name], sub_word, e[:args], *opts].compact.reject(&:empty?).join(" ")
    end

    # ---------- rendering ----------

    def short_help
      out = ["flk: fly.io-style workflow for local Firecracker microVMs", "",
             "Usage: flk COMMAND [SUBCOMMAND] [ARGS] [-a APP] [--help]", ""]
      GROUPS.each do |g|
        out << g
        LIST.select { _1[:group] == g && !_1[:hidden] }.each do |c|
          head = c[:subs] ? "#{c[:name]} #{c[:subs].reject { _1[:hidden] }.map { _1[:name] }.join('|')}" : [c[:name], c[:args]].compact.join(" ")
          out << (head.size > 30 ? "  #{head}\n  #{' ' * 31}#{c[:summary]}" : format("  %-30s %s", head, c[:summary]))
        end
        out << ""
      end
      out << "Guides: flk help TOPIC"
      TOPICS.each { |t, d| out << format("  %-30s %s", t, d) }
      out << ""
      out << "flk help COMMAND     details for one command (or: flk COMMAND --help)"
      out << "flk help --all       full reference: concepts, config, every command, the guides"
      out << "flk context          what flk sees right now, and what to do next (--all: whole host)"
      out << "State lives in #{ROOT}"
      out.join("\n")
    end

    def command_help(cmd, sub = nil)
      e = sub || cmd
      out = ["Usage: #{usage(cmd, sub)}", "", e[:summary]]
      aliases = Array(e[:aliases])
      out << "Aliases: #{aliases.join(', ')}" if aliases.any?
      out << "Blocks: #{e[:blocks]}" if e[:blocks]
      if !sub && cmd[:subs]
        out << "" << "Subcommands#{" (default: #{cmd[:default_sub]})" if cmd[:default_sub]}:"
        cmd[:subs].each do |s|
          u = usage(cmd, s).delete_prefix("flk #{cmd[:name]} ")
          out << (u.size > 34 ? "  #{u}\n  #{' ' * 35}#{s[:summary]}" : format("  %-34s %s", u, s[:summary]))
        end
      end
      if Array(e[:opts]).any?
        out << "" << "Options:"
        e[:opts].each { |o| out << format("  %-22s %s", switches(o).join(", "), desc(o)) }
      end
      notes = Array(sub ? sub[:notes] : nil) + Array(cmd[:notes])
      if notes.any?
        out << "" << "Notes:"
        notes.each { out << "  - #{_1}" }
      end
      out << "" << "Global: -a, --app APP   act on this app instead of the one in ./flk.toml"
      out.join("\n")
    end

    # Markdown command reference for `flk help --all`.
    def reference_md
      out = []
      GROUPS.each do |g|
        out << "### #{g}" << ""
        LIST.select { _1[:group] == g }.each do |c|
          entries = c[:subs] ? c[:subs].map { [c, _1] } : [[c, nil]]
          out << "#### flk #{c[:name]}" << ""
          out << c[:summary] + (c[:aliases] ? " (aliases: #{c[:aliases].join(', ')})" : "") << "" if c[:subs]
          entries.each do |cmd, sub|
            e = sub || cmd
            out << "- `#{usage(cmd, sub)}`: #{e[:summary]}"
            out << "  - aliases: #{e[:aliases].join(', ')}" if e[:aliases] && sub
            out << "  - aliases: #{cmd[:aliases].join(', ')}" if cmd[:aliases] && !sub
            out << "  - default when no subcommand is given" if sub && cmd[:default_sub] == sub[:name]
            Array(e[:opts]).each { |o| out << "  - `#{switches(o).join(', ')}`: #{desc(o)}" }
            out << "  - **blocks**: #{e[:blocks]}" if e[:blocks]
            Array(sub && sub[:notes]).each { out << "  - #{_1}" }
          end
          Array(c[:notes]).each { out << "- #{_1}" }
          out << ""
        end
      end
      out.join("\n")
    end

    # "`flk status`, ... take --json; `flk config show`, ... always print JSON"
    def json_summary
      flagged, always = [], []
      LIST.each do |c|
        (c[:subs] ? c[:subs].map { [c, _1] } : [[c, nil]]).each do |cmd, sub|
          e = sub || cmd
          next unless e[:json]
          name = "`flk #{[cmd[:name], sub&.dig(:name)].compact.join(' ')}`"
          (desc(Array(e[:opts]).find { switches(_1).include?("--json") }).start_with?("Accepted") ? always : flagged) << name
        end
      end
      "#{flagged.join(', ')} take `--json`; #{always.join(', ')} always print JSON"
    end

    # bash completion from the table: commands, subcommands, options, and
    # live app names (-a) and machine IDs (ID arguments).
    def bash_completion
      cmds = LIST.reject { _1[:hidden] }.flat_map { [_1[:name], *Array(_1[:aliases])] }
      cases = LIST.map do |c|
        subs = Array(c[:subs]).reject { _1[:hidden] }
        sub_cases = subs.map do |s|
          words = Array(s[:opts]).flat_map { switches(_1).map { |w| w.split.first } }
          ids = s[:args].to_s.include?("ID") ? " $(__flk_ids)" : ""
          "        #{s[:name]}) COMPREPLY=($(compgen -W \"#{words.join(' ')}#{ids}\" -- \"$cur\")) ;;"
        end
        words = Array(c[:opts]).flat_map { switches(_1).map { |w| w.split.first } }
        own = c[:args].to_s.include?("ID") ? " $(__flk_ids)" : ""
        own += " #{TOPICS.keys.join(' ')} #{cmds.join(' ')}" if c[:name] == "help"
        own += " bash" if c[:name] == "completion"
        body = if subs.any?
                 <<~SH.chomp
                   if [[ $cword -eq $((cmd_at + 1)) ]]; then
                         COMPREPLY=($(compgen -W "#{subs.map { _1[:name] }.join(' ')} #{words.join(' ')}" -- "$cur"))
                       else
                         case "${words[cmd_at + 1]}" in
                   #{sub_cases.join("
")}
                         esac
                       fi
                 SH
               else
                 %(COMPREPLY=($(compgen -W "#{words.join(' ')}#{own}" -- "$cur")))
               end
        "    #{[c[:name], *Array(c[:aliases])].join('|')})\n      #{body} ;;"
      end
      <<~SH
        # bash completion for flk (generated by `flk completion bash`)
        # IDs of the app named by -a on the line, or the one in this directory
        __flk_ids() {
          local i app=()
          for ((i = 1; i < ${#COMP_WORDS[@]} - 1; i++)); do
            [[ ${COMP_WORDS[i]} == -a || ${COMP_WORDS[i]} == --app ]] && app=(-a "${COMP_WORDS[i + 1]}")
          done
          flk "${app[@]}" machine list --json 2>/dev/null | sed -n 's/.*"id": "\\([0-9a-f]*\\)".*/\\1/p'
        }
        __flk_apps() { flk apps list --json 2>/dev/null | sed -n 's/.*"name": "\\([^"]*\\)".*/\\1/p'; }
        _flk() {
          local cur=${COMP_WORDS[COMP_CWORD]} prev=${COMP_WORDS[COMP_CWORD-1]} cword=$COMP_CWORD
          local words=("${COMP_WORDS[@]}") cmd_at=1
          case $prev in
            -a|--app) COMPREPLY=($(compgen -W "$(__flk_apps)" -- "$cur")); return ;;
            -i|--instance) COMPREPLY=($(compgen -W "$(__flk_ids)" -- "$cur")); return ;;
            --path|--from-dir) COMPREPLY=($(compgen -f -- "$cur")); return ;;
          esac
          while [[ ${words[cmd_at]} == -a || ${words[cmd_at]} == --app ]]; do cmd_at=$((cmd_at + 2)); done
          if [[ $cword -eq $cmd_at ]]; then
            COMPREPLY=($(compgen -W "#{cmds.join(' ')} --help --version -a" -- "$cur")); return
          fi
          case "${words[cmd_at]}" in
        #{cases.join("
")}
          esac
        }
        complete -F _flk flk
      SH
    end

    def to_h
      ser = lambda do |e, parent = nil|
        h = { "name" => e[:name], "usage" => parent ? usage(parent, e) : usage(e), "summary" => e[:summary] }
        h["aliases"] = e[:aliases] if e[:aliases]
        h["args"] = e[:args] if e[:args]
        h["options"] = Array(e[:opts]).map { |o| { "switches" => switches(o), "description" => desc(o) } }
        h["json"] = !!e[:json]
        h["blocks"] = e[:blocks] if e[:blocks]
        h["notes"] = e[:notes] if e[:notes]
        if e[:subs]
          h["default_subcommand"] = e[:default_sub]
          h["subcommands"] = e[:subs].map { ser.call(_1, e) }
        end
        h
      end
      {
        "schema" => JSON_SCHEMA, "version" => VERSION, "state_dir" => ROOT,
        "global_options" => GLOBAL_OPTS.map { { "switches" => switches(_1), "description" => desc(_1) } },
        "exit_codes" => EXIT_CODES.transform_keys(&:to_s),
        "commands" => LIST.map { ser.call(_1) },
        "topics" => TOPICS
      }
    end
  end
end
