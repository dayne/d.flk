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
  machine stops, the next one takes over.
- **Lifecycle**: when the app process exits, its VM powers off (state
  `stopped`) and flk hands its host ports on right away (a hook on flk's
  tmux server runs `flk ports reap`).
- **Desired state**: flk remembers whether you want each machine running.
  start/restart/deploy/scale mean yes, `flk machine stop` means no; an app
  exiting on its own changes nothing. `flk resume` starts every machine that
  should be running; `flk stop-all` stops them all gracefully but keeps
  them marked as running, which is what the host does at shutdown. `flk machine stop` sends the app SIGTERM, then kills the VM after
  `kill_timeout`.

Inside every machine: `FLY_APP_NAME`, `FLY_MACHINE_ID`, `FLY_PRIVATE_IP`,
`FLY_REGION=local`, the `FLK_*` equivalents, `FLK_RELEASE`, plus `[env]`
and secrets.

## Rules for agents and scripts

- **Never hangs without a terminal.** `flk logs` prints and exits unless
  stdout is a terminal (`-f` forces following). `flk apps destroy` needs
  `--yes`. `flk console` refuses to run; use `flk logs` instead.
- **One command blocks by design:** `flk proxy` forwards until it's killed.
  Run it in the background, and usually skip it altogether: machine IPs are
  reachable from the host (`curl http://172.30.0.10:8080/`).
- **Machine-readable output:** {{JSON_COMMANDS}}. Commands whose output is
  always JSON also accept `--json`; with several IDs they print one array.
- **Arguments are checked strictly.** An unknown option, a missing argument or
  an extra argument is an error that names the problem and points at
  `flk help COMMAND`. Nothing is silently ignored.
- **Errors** go to stderr as `Error: ...`, usually ending with the command
  that fixes them. The exit code is 1.
- **Run deploy from the app directory.** `deploy` and `launch` read the
  config from the current directory. `-a` alone isn't enough for them.
- **Slow commands:** `deploy` builds an image and boots each machine, waiting
  up to 30s per machine for `internal_port`. Expect a minute or more.
- **"short-name ... did not resolve"** on deploy: podman has no search
  registries (common on Ubuntu/Debian). flk prints a one-line fix that
  needs no root; using the full name (`FROM docker.io/library/ruby:3.3`)
  also works. `flk doctor` warns about it ahead of time.
- **Root** is only needed once, for `sudo ./setup-host.sh`, and again only if
  `flk doctor` / `flk context` say so. Day-to-day commands never need sudo.

## Common workflows

New app from a directory with a Dockerfile:

    flk launch --no-deploy            # writes flk.toml if missing, registers the app
    # edit flk.toml: internal_port, [[mounts]], [[services]] ...
    flk volumes create data --size 1  # one per machine, if [[mounts]] is used
    flk secrets set API_TOKEN=... --stage
    flk deploy
    flk status --json                 # machines, IPs, states

Debug a machine that won't stay up:

    flk status                        # state stopped?
    flk logs -i ID -n 200             # app output and boot messages (exits by itself)
    flk machine status ID             # record, config, timestamps
    flk machine start ID

Change config or code: edit, then `flk deploy`. Every deploy is a new release
and rolls the machines one at a time.

Scale: `flk volumes create data --size 1` (if `[[mounts]]` is used), then
`flk scale count 2`.

Expose on the LAN: for an `[http_service]` app add `[flk] http_port = N`;
otherwise add `[[services]]` with `[[services.ports]] port = N`. N >= 1024.
Deploy, then check `flk ports`.

Clean up: `flk apps destroy APP --yes` (machines, volumes, secrets, images:
everything). `flk apps prune` removes images left by apps destroyed before
that was the case.

After a reboot: with `sudo ./setup-host.sh --install-service` done once,
nothing to do: `flk-net.service` rebuilds the network and
`flk-machines.service` runs `flk resume` (and `flk stop-all` at shutdown).
Without it: `sudo ./setup-host.sh`, then `flk resume`. `flk doctor` warns
while the boot service is missing.

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
  (allow with `sudo FLK_MIN_PORT=N ./setup-host.sh`) and ports a host process
  listens on outside loopback. `flk ports` shows blocked ports and why.
- `kill_timeout`: `30`, `"30s"` or `"2m"`. Default 10, at most {{MAX_KILL_TIMEOUT}} seconds.
- `[[vm]]`: `cpus`, `memory` (`"1gb"`, `"512mb"`), `memory_mb`, or `size`
  (`shared-cpu-Nx` = 256MB x N, `performance-cpu-Nx` = 2GB x N)
- `[experimental]`: `cmd`, `entrypoint` (override the image's)
- `[flk]` (flk only): `http_port` (host port for `[http_service]`), `kernel_args`,
  `rootfs_extra_mb` (default 512)

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
