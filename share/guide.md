# flk reference (v{{VERSION}})

flk runs the fly.io workflow (`launch`, `deploy`, `machine`, `volumes`,
`secrets`) on a local Linux host, using Firecracker microVMs. It reads
`flk.toml`, or an existing `fly.toml` unchanged.

This page is the complete reference, written for people and AI agents alike.
`flk help --all --json` prints the command table as JSON, and `flk context`
shows the live state with suggested next steps.

## Start here

1. `flk context`: host health, the app for the current directory, its
   machines and ports, and the next steps that apply right now.
2. Do the first next step. Run `flk context` again to confirm.
3. `flk help COMMAND` shows the exact options for one command.

## Mental model

- **App**: a directory containing `flk.toml` (or `fly.toml`). Its name is the
  `app = "..."` key. Commands run inside that directory act on it; `-a APP`
  picks another app from anywhere.
- **Release**: every `flk deploy` builds the image (podman, or docker) and
  turns it into an ext4 root filesystem `vN`. The two most recent are kept.
- **Machine**: one Firecracker VM running a release. Each machine has an ID
  (hex; any unique prefix works), a generated name, and a fixed IP on
  `172.30.0.0/24`, reachable from the host directly. The root filesystem is
  thrown away on every deploy, as on Fly.
- **Root disk**: each machine's `/` is its own copy of the release's
  filesystem, as big as the image's files plus a quarter plus
  `[flk] rootfs_extra_mb` (512MB unless set). What the app writes or
  installs on `/` survives stops, restarts and host reboots, but not a
  deploy or rollback, which start from the release image again.
  `flk machine extend ID --size GB` grows one machine's `/` in place
  (kept until the next deploy); `rootfs_extra_mb` sets the room for every
  deploy; data that must last belongs on a volume.
- **Volume**: a persistent ext4 disk. `[[mounts]] source = "data"` needs one
  free volume named `data` *per machine*. A volume stays paired with its
  machine across deploys.
- **Secrets**: env vars stored outside the config (`secrets.json`, mode 0600).
  Changing them restarts running machines unless `--stage` is given.
- **Host ports**: `[[services.ports]] port = N` forwards host port N (on every
  host address) to the first running machine that asks for it. When that
  machine stops, the next one takes over. **Not on 127.0.0.1**: the
  forwarding skips loopback, so from the host itself connect to the host's
  LAN IP (shown by `flk ports`) or the machine IP; `flk proxy` gives a
  loopback port for TCP.
- **Lifecycle**: when the app process exits, its VM powers off (state
  `stopped`) and flk hands its host ports on right away (a hook on flk's
  tmux server runs `flk ports reap`). Then the restart policy decides:
  by default a crash or non-zero exit is restarted, a clean exit isn't.
- **Desired state**: flk remembers whether you want each machine running.
  start/restart/deploy/scale mean yes, `flk machine stop` means no; an app
  exiting on its own changes nothing. `flk resume` starts every machine that
  should be running; `flk stop-all` stops them all gracefully but keeps
  them marked as running, which is what the host does at shutdown. `flk machine stop` sends the app SIGTERM, then kills the VM after
  `kill_timeout`.

Inside every machine, like a container: `/dev/fd`, `/dev/stdin`,
`/dev/stdout`, `/dev/stderr`, `/dev/pts`, `/dev/shm`; the app's stdin is
the serial console. Env: `FLY_APP_NAME`, `FLY_MACHINE_ID`, `FLY_PRIVATE_IP`,
`FLY_REGION=local`; `FLK_APP_NAME`, `FLK_MACHINE_ID`, `FLK_IP`,
`FLK_HOSTNAME` (the machine's name), `FLK_RELEASE` (`vN`), `FLK_PREFIX`,
`FLK_GATEWAY`, `FLK_DNS`, `FLK_STDIN`; plus `[env]` and secrets. Writing
a Dockerfile for it: `flk help dockerfile`.

## Rules for agents and scripts

- **Never hangs without a terminal.** `flk logs` prints and exits unless
  stdout is a terminal (`-f` forces following). `flk apps destroy` needs
  `--yes`. `flk console` refuses to attach; type to the app with
  `flk console ID --send TEXT [--wait-log REGEX]` and read `flk logs`.
- **One command blocks by design:** `flk proxy` forwards until it's killed.
  Run it in the background, and usually skip it altogether: machine IPs are
  reachable from the host (`curl http://172.30.0.10:8080/`).
- **Machine-readable output:** {{JSON_COMMANDS}}. Commands whose output is
  always JSON also accept `--json`; with several IDs they print one array.
  `context`, `doctor` and `help --all` JSON carry `"schema": {{SCHEMA}}`:
  new fields can appear without notice (ignore what you don't know), while
  renaming, removing or changing the type of a field bumps the number.
  For polling, `flk context --all --json --no-host` skips the host checks
  (run `flk doctor --json` less often).
- **Arguments are checked strictly.** An unknown option, a missing argument or
  an extra argument is an error that names the problem and points at
  `flk help COMMAND`. Nothing is silently ignored.
- **Errors** go to stderr as `Error: ...`, usually ending with the command
  that fixes them, or followed by a `Next:` line. The exit code is 1. A
  deploy that fails before touching any machine ends with
  `Error: build failed; machines unchanged (still on vN)` (or `deploy
  failed; ...`): nothing needs stopping or rolling back. Just above it, a
  failed build shows what the build said (its error lines), the step
  that failed, and `Build log: FILE`: every build's whole output is kept
  in `APP/builds/` (each kept release's as `vN.log`, `build_log` in
  `flk releases --json`; the last 3 failed builds as `vN-failed-TIME.log`).
- **An app can live on another host.** With `[flk] host = "NAME"` in its
  flk.toml, the commands about the app run on that flk host over ssh, and
  `deploy` sends the directory first; `-H NAME` (or `FLK_HOST=NAME`) sends
  any command, `-H local` keeps it here. Output, `--json` and exit codes
  are that host's; exit 255 means ssh couldn't connect. `flk peers --json`
  lists the hosts. Details: `flk help remote`.
- **Where the config is.** `launch` uses the current directory. After an
  app's first `launch` or `deploy` there, flk remembers its config file
  (`config_path` in `status --json`), so `flk -a APP deploy` and
  `flk -a APP config show` work from anywhere.
- **Slow commands:** `deploy` builds an image and boots each machine, waiting
  up to 30s per machine for `internal_port`. Expect a minute or more.
- **"short-name ... did not resolve"** on deploy: podman has no search
  registries (common on Ubuntu/Debian). flk prints a one-line fix that
  needs no root; using the full name (`FROM docker.io/library/ruby:3.3`)
  also works. `flk doctor` warns about it ahead of time.
- **Root** is only needed once, for `sudo {{SRC}}/setup-host.sh`, and again only if
  `flk doctor` / `flk context` say so. Day-to-day commands never need sudo.

## Guides

Short guides for each stage follow at the end of this page, and each one is
also its own help page: {{TOPICS}}.

## Config (flk.toml / fly.toml subset)

Every key below, with its type, default and a line of description, is
also in `flk help --all --json` as `config_keys`:
`{ key, table, name, type, default, flk_only, read, doc }`. `read` is
false for the fly.toml keys flk accepts and ignores; a key that isn't
listed gets an "unknown key" warning from `flk config show` and deploy.
To ask whether this flk has a setting, look for its `key` (such as
`mounts.seed` or `checks.NAME.command`).

- `app`: name; lowercase letters, digits, dashes
- `[build]`: `dockerfile` (default `Dockerfile`), `image` (prebuilt, skips the build), `args`
- `[env]`: plain env vars
- `[[mounts]]`: `source` (volume name), `destination` (path in the VM).
  `seed = true` (flk only): a volume that's empty when its machine is
  about to boot is first filled with what the image has at `destination`,
  as Docker fills a new named volume: files, directories and symlinks with
  their owners and modes, and the volume's root owned like the directory
  itself. For a home directory on a volume, or a config directory the
  program ships with. Only an empty volume is seeded, so the app's own
  changes are never overwritten, and a later image's new files don't
  arrive; `flk events` has a `volume.seeded`. Not copied: setuid bits,
  hard links (they become separate files) and device files. If the files
  don't fit, the machine boots with the volume still empty and a warning
  that says so; the next start tries again.
- `[http_service] internal_port`, or the first `[[services]] internal_port`:
  the port flk waits for after boot and prints as the app URL. `[http_service]`
  is reachable on the machine IP; to also serve it on a host port (and the
  LAN), set `[flk] http_port = N`. Same rules as `[[services.ports]]`.
- `[[services]]`: `internal_port`, `protocol` (`tcp`/`udp`), and
  `[[services.ports]] port`: host ports to forward. Refused: ports below 1024
  (allow with `sudo FLK_MIN_PORT=N {{SRC}}/setup-host.sh`) and ports a host process
  listens on outside loopback. `flk ports` shows blocked ports and why.
- `kill_timeout`: `30`, `"30s"` or `"2m"`. Default 10, at most {{MAX_KILL_TIMEOUT}} seconds.
- `[[restart]]`: `policy` = `"on-failure"` (default: restart after a non-zero
  exit or a crash), `"always"` (after any exit) or `"never"`; `retries`
  (default 10; fly's `max_retries` is read too) restarts in a row, with 1, 2, 4... up to 60s between them,
  before giving up. A run of 10+ minutes resets the count, and so does
  starting the machine yourself. flk's own stops (`machine stop`,
  `stop-all`, deploys) are never restarted.
- `[[vm]]`: `cpus`, `memory` (`"1gb"`, `"512mb"`), `memory_mb`, or `size`
  (`shared-cpu-Nx` = 256MB x N, `performance-cpu-Nx` = 2GB x N).
  `huge_pages = "2M"` (flk): guest memory from a reserved hugetlbfs pool;
  the host needs `vm.nr_hugepages` of memory/2MB free, which deploy and
  start check, printing the sysctl to run. That memory is held whether the
  guest uses it or not and is never swapped. Memory must be whole 2MB.
- `[experimental]`: `cmd`, `entrypoint` (override the image's)
- `[checks.NAME]`: health checks a deploy waits for: `type` = `"tcp"`
  (`port`), `"http"` (`port`, `path`; 2xx/3xx passes), or flk's own:
  - `"log"`: `match` = a regex for a console line since boot; `^` and `$`
    match at each line's start and end.
  - `"exec"`: `command` = `["PROG", "ARG"...]` or a string for `sh -c`,
    run in the guest through flk-agent (as `flk exec`; `user`, default the
    image's USER); exit 0 passes. `timeout` per try, default 10s. The
    command's last output line is in the failure. Proves what a port
    can't: the volume is mounted, the tool runs, the app's own health
    command passes.
  - `"udp"`: `port`, `send` (text) or `send_hex` (bytes as hex), and
    `expect` (a regex the reply must match, bytes as `\xFF` in a
    single-quoted TOML string; default any reply). `timeout`
    per try, default 2s. For a Steam game's query port, A2S_INFO is
    `send_hex = "FFFFFFFF54536F7572636520456E67696E6520517565727900"`;
    any reply (the info, or the challenge newer servers send first)
    means the server answers.
  - `"disk"`: `path` = a directory in the machine (default `/`), and
    `max_percent` (default 90): fails when the filesystem holding it is
    that full or more, saying how full and how much is free. Measured
    with `df` in the guest through flk-agent. With an `interval` it is
    the warning before a volume or the root disk fills up, which is how
    a server dies quietly.

  Checks run one after another, retried each second; each must pass within
  `grace_period` (default 60s) or the machine goes back to its previous
  release and the deploy stops. Also read: `[[services.tcp_checks]]`,
  `[[services.http_checks]]` (on that service's port), `[[http_service.checks]]`.

  `interval` (`"5m"`, `90`): also try the check that often while the
  machine runs. `flk check` runs every check by hand; `flk-check.timer`
  (`--install-service`) runs the ones with an interval, at most once a
  minute. Each machine keeps its last results (`flk status`, `checks` in
  `status --json`), and a change is an event (`check.failed`,
  `check.recovered`). Checks report and never restart anything. A `log`
  check that has passed stays passed until the next boot.
- `[deploy] preflight = "CMD"` (flk only): a host command `flk deploy`
  runs first, in the config's directory, with `FLK_APP` and `FLK_RELEASE`
  (the version this deploy will make). A non-zero exit stops the deploy
  before any backup or build (`preflight failed; machines unchanged`, with
  the command's last line); `flk deploy --no-preflight` skips it. For
  checks that would otherwise cost a long build: a stale download pin, a
  missing secret file. `flk build` doesn't run it.
- `[flk] internal_hosts = true` (flk only): fly's `.internal` names, from
  `/etc/hosts` rather than DNS. The app's machines get a line per machine
  on this host: `IP APP.internal ID.vm.APP.internal NAME.vm.APP.internal`
  (`APP.internal` only for running machines, so it names the app's live
  ones; most resolvers return every address). flk writes it at boot and
  rewrites it in running machines whenever a machine starts or stops
  (that needs flk-agent in the release, which needs Go). Only names: no
  SRV/TXT records, no `top1.nearest.of`. Default false: other apps'
  `/etc/hosts` are left alone.
  Machine JSON (`status`, `context`, `machine list --json`) carries each
  machine's names as `internal_names` (`[]` when the key is off).
- `[flk] keep_releases`: release images kept for `flk releases rollback`
  (default 2).
- `[flk] bind` (flk only): forward this app's host ports only on these host
  addresses (`"10.47.11.3"` or a list) instead of on every host address;
  `"all"` overrides a host-wide `bind`. Apps can then share a port on
  different addresses. Needs the port helper from a current
  `sudo {{SRC}}/setup-host.sh`.
- `[flk] rootfs_extra_mb` (flk only; default 512): free space on `/` beyond
  the image's files, in MB. A release's root filesystem is made as big as
  the files in the image, plus a quarter, plus this; that is all the room
  the app has for what it writes outside its volumes (packages installed
  at run time, caches, logs, `/tmp` when the image doesn't mount a tmpfs
  there). It takes effect at the next `flk deploy`, for every machine. The
  file is sparse, so a generous value costs host disk only as it's used.
  `flk machine extend ID --size GB` grows a machine that's already full
  without a deploy.
- `[flk] log_max_mb` (flk only): the size, in MB, at which each of this
  app's machines moves `console.log` to `console.log.1` and starts a new
  one. Without it the host's `FLK_LOG_MAX_MB` applies (default 10). A
  machine keeps up to twice the limit on disk, and `flk logs --boot` can
  show a boot's start only while it is in one of the two files, so raise
  it for an app that writes a lot between restarts. It takes effect at
  the next `flk deploy`.
- `[flk]` (flk only): `http_port` (host port for `[http_service]`), `kernel_args`,
  `stdin` (`"console"`, the default: the app
  reads what you type in `flk console`; `"null"`: /dev/null, like
  `docker run` without `-i`)
- `[flk.backup]` (flk only): how `flk volumes backup` keeps the app from
  writing during the copy. `mode` = `"stop"` (default: stop the machine,
  copy, start it), `"live"` (copy while it runs, after the `pre` hooks made
  the app flush and stop writing) or `"pause"` (freeze the VM during the
  copy: like a power cut, which journaled filesystems and SQLite survive).
  `pre` / `post`: hooks run in order, each a host command run in the
  flk.toml's directory (with `FLK_APP`, `FLK_MACHINE`, `FLK_MACHINE_IP`) or
  `{ console = "LINE", wait = "REGEX", timeout = 60 }` typed into the app's
  stdin. `post` hooks run even if the backup failed. `settle` (default 5):
  seconds between `pre` and the copy, for the guest to write out its cache.
  `keep`: backups per volume. `verify`: a host command that checks a
  backup after e2fsck (by `flk volumes backup` and `flk volumes verify`),
  run in the flk.toml's directory with `FLK_BACKUP` (the image file),
  `FLK_APP`, `FLK_VOLUME` and `FLK_BACKUP_REASON` (`backup`,
  `before_deploy` or `verify`); exit 0 means good. It can read files without
  mounting: `debugfs -R 'stat /world/level.dat' "$FLK_BACKUP"`.
  `before_deploy = true`: deploys and rollbacks back up each machine's
  volumes while it's stopped for the update (a full copy unless the backup
  dir is on XFS/btrfs with the volumes: it adds to the downtime). If the new
  release fails its health checks, the machine goes back with its volumes
  as they were; `flk releases rollback --with-volumes` uses these backups
  later. They're ordinary backups (`reason = "before_deploy"`), pruned by
  `keep` like the rest, and copied to `backup_copy_to` (host.toml) like
  the rest, once the roll is over (not during the downtime). If one fails (its verify hook, say), the deploy
  stops and the machine starts again on its old release; `flk deploy
  --no-backup` skips them. A machine whose release never passed its
  health checks only gets a warning from a failed verify: there's nothing
  good on its volumes to protect. Example (Minecraft, over its console):
  `mode = "live"`, `pre = [{ console = "save-off" }, { console = "save-all flush", wait = "Saved the game" }]`,
  `post = [{ console = "save-on" }]`.

Everything else in a fly.toml (regions, concurrency, statics) is ignored;
a key flk doesn't know at all gets a warning. Every key, annotated:
`{{SRC}}/examples/reference/flk.toml`.
`flk config show` prints what flk understood.

## Events

`flk events` reads a history kept in the state dir (`events.jsonl`), written
by every flk command and the tmux exit hook. `--json` prints one object
per line: `{ "at", "app", "machine", "type", "release"?, "detail"?, "log"?, "kernel"? }`
(`log`: a file with the whole story, such as a failed build's output;
`kernel`: the guest kernel a machine booted, on the events of a boot,
and `detail` says when it isn't the one of its boot before).
`type` is one of a fixed set (new ones may be added; existing ones keep
their meaning). `detail` is free text on one line: a cause that had
several lines (rsync's, podman's) has them joined with " · ".

{{EVENT_TYPES}}

A deploy that fails before it touches a machine (the build, or a check
before the roll) is a `deploy.failed` whose `release` is the unchanged
current one and whose `detail` starts with `build failed; machines
unchanged` (or `deploy failed; ...`); after a failed build, `detail` ends
with the build's own first error line and `log` names its saved output.
A health-check failure during the
roll is a `deploy.failed` for the new release, its `detail` starting with
`vN failed its health checks`.

## Commands

Global options for every command: `-a, --app APP`, and `-H, --on-host HOST`
to run it on another flk host (`flk help remote`). `flk COMMAND --help`
works everywhere.

{{COMMANDS}}

## Exit codes

{{EXIT_CODES}}

## Environment variables

- `FLK_HOME`: state directory (default `$XDG_DATA_HOME/flk`, i.e. `~/.local/share/flk`)
- `FLK_ENGINE`: `podman` or `docker` (default: whichever is installed, podman first)
- `FLK_FIRECRACKER`, `FLK_KERNEL`: override the binary / guest kernel from `flk setup`
- `FLK_BRIDGE`, `FLK_SUBNET`, `FLK_TAPS`: must match what `setup-host.sh` used
- `FLK_DNS`: resolvers handed to machines (default `1.1.1.1 9.9.9.9`)
- `FLK_TMUX_SOCKET`: name of flk's own tmux server (default `flk`)
- `FLK_LOG_MAX_MB`: size at which a machine's `console.log` rotates to `console.log.1` (default 10); an app sets its own with `[flk] log_max_mb`
- `FLK_HOST`: run commands on this flk host, as `-H` does; `local` keeps them here whatever flk.toml says
- `FLK_SSH`: the ssh command used to reach another flk host (default `ssh`)
- `FLK_REMOTE_FLK`: flk's path on the other host, when it isn't on its `PATH` or in `~/.local/bin`
- `NO_COLOR`: plain output

## Files

    {{ROOT}}/
      bin/firecracker  kernel/vmlinux
      apps/APP/
        app.json  secrets.json  volumes.json
        images/vN.ext4
        volumes/vol_xxx.ext4
        machines/ID/
          machine.json  vm.json  rootfs.ext4  config.ext4
          console.log  console.log.1  firecracker.log  fc.sock  pid
      src/APP/            an app's directory, sent here by another host's deploy
      remote_apps.json    apps this host deployed to another one, and where

The flk source is at `{{SRC}}`. Host setup lives in `setup-host.sh`, the host
checker in `flk-sanity.sh`, and end-to-end tests in `tests/run.sh`. Known rough
edges are listed in `TODO.md`.

{{TOPIC_PAGES}}
