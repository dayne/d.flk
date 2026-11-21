module Flk
  # Every flk.toml / fly.toml key flk knows: the ones it reads, and the
  # fly.toml keys it accepts and ignores. One table for the parser's
  # unknown-key warnings (AppConfig::KNOWN_KEYS) and for `config_keys` in
  # `flk help --all --json` (flkforge's explain, and anything asking "does
  # this flk read KEY"). The prose is the Config section of share/guide.md;
  # tests/cases/00-config.sh checks that it names every key read here.
  module ConfigKeys
    module_function

    # section id => how its TOML table is written
    TABLES = {
      "" => "", "build" => "[build]", "env" => "[env]", "experimental" => "[experimental]", "deploy" => "[deploy]",
      "vm" => "[[vm]]", "mounts" => "[[mounts]]", "services" => "[[services]]", "services.ports" => "[[services.ports]]",
      "restart" => "[[restart]]", "http_service" => "[http_service]", "check" => "[checks.NAME]", "flk" => "[flk]",
      "flk.backup" => "[flk.backup]"
    }.freeze

    # [section, name, type, default, doc]; :flk as a sixth element marks
    # a key fly.toml doesn't have. Types: string, integer, boolean, table,
    # list, duration (30, "30s" or "2m"), command (a string for sh -c, or
    # a list), regex.
    READ = [
      ["", "app", "string", nil, "The app's name: lowercase letters, digits, dashes. Required."],
      ["", "kill_timeout", "duration", 10, "Seconds between the stop signal and a hard kill; at most #{AppConfig::MAX_KILL_TIMEOUT}."],
      ["", "build", "table", nil, "How the image is made: [build]."],
      ["", "env", "table", nil, "Environment variables for the app: [env]."],
      ["", "experimental", "table", nil, "cmd and entrypoint overrides: [experimental]."],
      ["", "deploy", "table", nil, "[deploy] preflight."],
      ["", "vm", "table", nil, "CPUs and memory of each machine: [[vm]] (the first one is used)."],
      ["", "mounts", "table", nil, "Volumes and where they mount: [[mounts]]."],
      ["", "services", "table", nil, "Ports the app listens on and host ports forwarded to them: [[services]]."],
      ["", "http_service", "table", nil, "The app's HTTP port: [http_service]."],
      ["", "checks", "table", nil, "Health checks a deploy waits for: [checks.NAME]."],
      ["", "restart", "table", nil, "What happens when the app exits on its own: [[restart]]."],
      ["", "flk", "table", nil, "Settings only flk has: [flk].", :flk],

      ["build", "dockerfile", "string", "Dockerfile", "The Dockerfile to build, relative to the config's directory."],
      ["build", "image", "string", nil, "A prebuilt image to run; skips the build."],
      ["build", "args", "table", nil, "Build arguments (ARG) for the Dockerfile."],

      ["env", "NAME", "string", nil, "One variable per key; names are letters, digits and underscores."],

      ["experimental", "cmd", "command", nil, "Replaces the image's CMD."],
      ["experimental", "entrypoint", "command", nil, "Replaces the image's ENTRYPOINT."],

      ["deploy", "preflight", "string", nil,
       "A host command a deploy runs first, in the config's directory, with FLK_APP and FLK_RELEASE; non-zero stops the " \
       "deploy before any backup or build.", :flk],

      ["vm", "cpus", "integer", 1, "Virtual CPUs."],
      ["vm", "memory", "string", nil, "Memory, as \"1gb\" or \"512mb\" (a bare number is MB)."],
      ["vm", "memory_mb", "integer", 256, "Memory in MB."],
      ["vm", "size", "string", nil, "A fly preset: shared-cpu-Nx (256MB x N) or performance-cpu-Nx (2GB x N)."],
      ["vm", "huge_pages", "string", nil, "\"2M\": guest memory from the host's reserved huge page pool.", :flk],

      ["mounts", "source", "string", nil, "The volume's name (flk volumes create NAME); one volume per machine."],
      ["mounts", "destination", "string", nil, "Where the volume mounts in the machine."],
      ["mounts", "seed", "boolean", false,
       "Fill the volume, while it's empty, with what the image has at destination (as Docker does for a new named volume).", :flk],

      ["services", "internal_port", "integer", nil, "The port the app listens on in the machine."],
      ["services", "protocol", "string", "tcp", "tcp or udp."],
      ["services", "ports", "list", nil, "Host ports forwarded to internal_port: [[services.ports]]."],
      ["services", "tcp_checks", "list", nil, "tcp checks on this service's internal_port (keys as [checks.NAME])."],
      ["services", "http_checks", "list", nil, "http checks on this service's internal_port (keys as [checks.NAME])."],

      ["services.ports", "port", "integer", nil, "A host port to forward; refused below 1024 or when a host process listens there."],

      ["restart", "policy", "string", "on-failure", "on-failure, always or never."],
      ["restart", "retries", "integer", 10, "Restarts in a row before giving up."],
      ["restart", "max_retries", "integer", nil, "Another name for retries."],

      ["http_service", "internal_port", "integer", nil, "The app's HTTP port; flk waits for it after boot."],
      ["http_service", "checks", "list", nil, "http checks on internal_port (keys as [checks.NAME])."],

      ["check", "type", "string", "tcp", "tcp, http, or flk's log, exec and udp."],
      ["check", "port", "integer", nil, "tcp, http, udp: the port in the machine (default: the service's internal_port)."],
      ["check", "path", "string", "/", "http: the path to GET; 2xx and 3xx pass."],
      ["check", "grace_period", "duration", 60, "How long after boot the check has to pass."],
      ["check", "timeout", "duration", nil, "exec (default 10) and udp (default 2): seconds per try."],
      ["check", "interval", "duration", nil, "Also try it this often while the machine runs (the flk-check timer, once a minute at most); results in flk status. Unset: only deploys run it."],
      ["check", "match", "regex", nil, "log: a console line since boot must match.", :flk],
      ["check", "command", "command", nil, "exec: run in the machine through flk-agent; exit 0 passes.", :flk],
      ["check", "user", "string", nil, "exec: who runs the command (default: the image's USER).", :flk],
      ["check", "send", "string", nil, "udp: the datagram to send, as text.", :flk],
      ["check", "send_hex", "string", nil, "udp: the datagram to send, as hex digits.", :flk],
      ["check", "expect", "regex", nil, "udp: the reply's bytes must match (default: any reply).", :flk],

      ["flk", "http_port", "integer", nil, "A host port forwarded to [http_service] internal_port.", :flk],
      ["flk", "bind", "list", nil, "Forward this app's host ports only on these host addresses (one, a list, or \"all\").", :flk],
      ["flk", "rootfs_extra_mb", "integer", 512, "Free space on / beyond the image's files, in MB; applies at the next deploy.", :flk],
      ["flk", "keep_releases", "integer", 2, "Release images kept for flk releases rollback.", :flk],
      ["flk", "internal_hosts", "boolean", false, "APP.internal names for this host's machines, in /etc/hosts.", :flk],
      ["flk", "stdin", "string", "console", "The app's stdin: console (what flk console types) or null (/dev/null).", :flk],
      ["flk", "kernel_args", "string", nil, "Extra guest kernel command line.", :flk],
      ["flk", "backup", "table", nil, "How flk volumes backup copies this app's volumes: [flk.backup].", :flk],

      ["flk.backup", "mode", "string", "stop", "stop (stop, copy, start), live (copy while running, after the pre hooks) or pause.", :flk],
      ["flk.backup", "pre", "list", nil, "Hooks before the copy: host commands, or { console, wait, timeout } typed to the app.", :flk],
      ["flk.backup", "post", "list", nil, "Hooks after the copy; they run even if the backup failed.", :flk],
      ["flk.backup", "settle", "integer", 5, "Seconds between the pre hooks and the copy.", :flk],
      ["flk.backup", "keep", "integer", nil, "Backups kept per volume (default: the host's backup_keep, else 7).", :flk],
      ["flk.backup", "verify", "string", nil, "A host command that checks a backup (FLK_BACKUP is the image); exit 0 means good.", :flk],
      ["flk.backup", "before_deploy", "boolean", false, "Back up each machine's volumes while it's stopped for a deploy or rollback.", :flk]
    ].freeze

    # fly.toml keys flk accepts without a warning and doesn't use.
    IGNORED = {
      "" => %w[primary_region kill_signal swap_size_mb console_command files processes statics metrics],
      "build" => %w[build-target build_target ignorefile builder builtin buildpacks settings],
      "vm" => %w[cpu_kind gpus gpu_kind processes kernel_args host_dedication_id persist_rootfs],
      "mounts" => %w[processes initial_size auto_extend_size_threshold auto_extend_size_increment auto_extend_size_limit
                     snapshot_retention scheduled_snapshots],
      "services" => %w[concurrency auto_stop_machines auto_start_machines min_machines_running processes script_checks],
      "services.ports" => %w[handlers force_https start_port end_port tls_options http_options proxy_proto_options],
      "restart" => %w[processes],
      "http_service" => %w[force_https auto_stop_machines auto_start_machines min_machines_running processes concurrency
                           http_options tls_options],
      "check" => %w[method headers protocol tls_skip_verify tls_server_name processes]
    }.freeze

    def key(section, name)
      return name if section.empty?
      "#{section == 'check' ? 'checks.NAME' : section}.#{name}"
    end

    # [{ key, table, name, type, default, flk_only, read, doc }]: read is
    # false for the fly.toml keys flk ignores.
    def all
      READ.map do |section, name, type, default, doc, flk|
        { "key" => key(section, name), "table" => TABLES.fetch(section), "name" => name, "type" => type, "default" => default,
          "flk_only" => flk == :flk, "read" => true, "doc" => doc }
      end + IGNORED.flat_map do |section, names|
        names.map do |name|
          { "key" => key(section, name), "table" => TABLES.fetch(section), "name" => name, "type" => nil, "default" => nil,
            "flk_only" => false, "read" => false, "doc" => "A fly.toml key: accepted, not used." }
        end
      end
    end

    # section => names, for the sections the parser checks for typos.
    def known(sections)
      sections.to_h do |s|
        [s, READ.select { _1[0] == s }.map { _1[1] } + IGNORED.fetch(s, [])]
      end
    end
  end
end
