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
`FLY_REGION=local`, the `FLK_*` equivalents, `FLK_RELEASE`, plus `[env]`
and secrets.

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
  that fixes them. The exit code is 1.
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

- `app`: name; lowercase letters, digits, dashes
- `[build]`: `dockerfile` (default `Dockerfile`), `image` (prebuilt, skips the build), `args`
- `[env]`: plain env vars
- `[[mounts]]`: `source` (volume name), `destination` (path in the VM)
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
  (default 10) restarts in a row, with 1, 2, 4... up to 60s between them,
  before giving up. A run of 10+ minutes resets the count, and so does
  starting the machine yourself. flk's own stops (`machine stop`,
  `stop-all`, deploys) are never restarted.
- `[[vm]]`: `cpus`, `memory` (`"1gb"`, `"512mb"`), `memory_mb`, or `size`
  (`shared-cpu-Nx` = 256MB x N, `performance-cpu-Nx` = 2GB x N)
- `[experimental]`: `cmd`, `entrypoint` (override the image's)
- `[flk] bind` (flk only): forward this app's host ports only on these host
  addresses (`"10.47.11.3"` or a list) instead of on every host address;
  `"all"` overrides a host-wide `bind`. Apps can then share a port on
  different addresses. Needs the port helper from a current
  `sudo {{SRC}}/setup-host.sh`.
- `[flk]` (flk only): `http_port` (host port for `[http_service]`), `kernel_args`,
  `rootfs_extra_mb` (default 512), `stdin` (`"console"`, the default: the app
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
  `keep`: backups per volume. Example (Minecraft, over its console):
  `mode = "live"`, `pre = [{ console = "save-off" }, { console = "save-all flush", wait = "Saved the game" }]`,
  `post = [{ console = "save-on" }]`.

Everything else in a fly.toml (regions, checks, concurrency, statics) is ignored.
`flk config show` prints what flk understood.

## Commands

Global option for every command: `-a, --app APP`. `flk COMMAND --help` works
everywhere.

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
- `FLK_LOG_MAX_MB`: size at which a machine's `console.log` rotates to `console.log.1` (default 10)
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

The flk source is at `{{SRC}}`. Host setup lives in `setup-host.sh`, the host
checker in `flk-sanity.sh`, and end-to-end tests in `tests/run.sh`. Known rough
edges are listed in `TODO.md`.

{{TOPIC_PAGES}}
