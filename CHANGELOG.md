# Changelog

What changed in flk, by version, for someone who runs it or reads its
CLI from a tool. Newest first. The reasons and the decisions behind each
change are in `docs/history.md`; open work is in `TODO.md`.

How versions work:

- `flk version` prints the version (`Flk::VERSION` in `lib/flk/util.rb`).
  `flk context --json` and `flk help --all --json` carry it as `version`.
- The number is `0.MINOR.PATCH`. A release that adds a command, an
  option, a flk.toml key or a JSON field raises MINOR. A release with
  only fixes raises PATCH.
- The CLI and its JSON only grow. A rename, a removal or a type change
  would be listed under "Changed", and would also raise `"schema"` in
  the JSON.
- Work merged to main since the last release is under "Unreleased". A
  release moves it under a new version heading, sets `Flk::VERSION` and
  gets the tag `vX.Y.Z`.
- "On the host" lists what to run once after updating. A change to the
  guest (flk's init or agent) reaches a machine at its next deploy.

Versions 0.1.0 to 0.5.0 were named afterwards, on 2026-11-21, from
`docs/history.md` and the git log. flk reported 0.1.0 the whole time,
so the commit named in each heading is what identifies them.

## Unreleased

### Added

- Each release and each boot records the guest kernel: `kernel:
  {version, sha256}` in `flk releases --json` and per machine in
  `flk status --json`. `flk releases` has a KERNEL column.
- `flk setup` says when it replaced the guest kernel, and `flk status`
  names the machines that still run the old one.
- The events of a boot carry `kernel`, and their `detail` says when the
  machine booted another kernel than before.
- `flk doctor --json` has `kernel`, and `flk context --json` has
  `flk.kernel`: the kernel machines boot from now on.
- Host checks on a schedule: `flk-check.timer` now also runs what
  `flk doctor` checks, every 5 minutes, and `flk check --host` runs them
  by hand. Events `host.problem` and `host.recovered` say when one
  changes; their `app` is null.
- `flk doctor --json`: every check has an `id` that stays the same
  while its label changes.
- Two doctor checks: room on the disks under flk's state and volumes
  (host setting `disk_warn_percent`, default 90), and, with the host
  setting `backup_warn_days`, a backed-up volume with no recent backup.

### Fixed

- `flk doctor` warned that machines weren't in a flk service when a
  machine ran on another tmux socket (the test suite's).

### On the host

- Nothing to run where `flk-check.timer` is installed: its next run
  includes the host checks.

## 0.6.0 (2026-11-21)

Health while running, and a machine's log since its boot.

### Added

- `[checks.NAME] interval = "5m"`: a check with an interval is tried
  again while the machine runs, not only at a deploy.
- `flk check [-i ID] [--all] [--due] [--json]` runs an app's checks now.
  It exits 2 when a check fails.
- `flk status` has a Checks table, and `flk status --json` and
  `flk machine list --json` have `checks` per machine:
  `{NAME: {type, interval, ok, at, since, detail}}`.
- Events: `check.recovered` is new. `check.failed` and `check.passed`
  now also come from `flk check`.
- `flk context` lists a failing check as a problem. `flk doctor` warns
  when checks have an interval and nothing runs them.
- `flk-check.timer` and `flk-check.service`: systemd runs the due checks
  every minute.
- `flk logs --boot [-n N]`: a machine's log from its latest boot on,
  from `console.log.1` too when the boot began before the last rotation.
- `[flk] log_max_mb = N`: an app's own size limit for `console.log`
  (default: the host's `FLK_LOG_MAX_MB`, 10).
- `CHANGELOG.md`, and version numbers that change.

### Fixed

- The guest's init sometimes logged `app exited with status 0` for an
  app that failed right at its start (1 boot in 60 on the reference
  host), so `[[restart]] policy = "on-failure"` could leave a crashed
  app stopped.
- A `log` check or `flk console --wait-log` whose regex has a character
  outside ASCII raised an error on a log with such bytes.
- `flk check`'s `log` check reads a boot 1MB at a time, so a large log
  no longer costs memory.

### On the host

- `sudo ./setup-host.sh --install-service` installs `flk-check.timer`.
  It doesn't stop machines.
- The init fix and `interval` reach an app at its next deploy.

## 0.5.0 (2026-11-17, commit 54772bf)

A running machine's directory, mounted on the host.

### Added

- `flk ssh mount PATH DIR [--user U] [--read-only]` mounts a directory
  of a running machine on the host with sshfs. Nothing listens in the
  guest: the image brings `sftp-server`, and flk starts it through its
  agent.
- `flk ssh unmount DIR|--all [--force]` and `flk ssh mounts [--json]`.
  `flk status --json` has `ssh_mounts`.
- `examples/devbox`: a whole app that uses it, with the Dockerfile lines
  for each distro in `flk help dockerfile`.

### On the host

- Optional: the `sshfs` package (`fuse-sshfs` on Fedora).

## 0.4.0 (2026-11-11, commit 2ebd093)

Making apps: build without deploying, more kinds of checks, and what
flkforge and lazyflk asked for.

### Added

- `flk build`: build the image and its root filesystem and report on it
  (user, command, sizes, mounts) without deploying.
- Image warnings at build and deploy: no user switch possible, no CMD, a
  mount over files in the image, a volume the app's user can't write, a
  `[[mounts]] source` that isn't a valid volume name.
- Checks of `type = "exec"` (a command in the guest) and `type = "udp"`
  (`send` or `send_hex`, and `expect`).
- `[deploy] preflight`: a host command that can stop a deploy before
  anything changes.
- `[[mounts]] seed = true`: a new, empty volume is filled from the image
  at its mount point.
- `flk help --all --json` has `config_keys`: every flk.toml key with its
  type, default and description.
- `flk machine extend ID --size GB` grows a machine's root disk in
  place.
- `flk releases log [VERSION|FILE] [--failed]` prints a build log.
- `flk context --json` has `next_steps_detail`, which says what kind
  each next step is.
- `flk config set` takes lists (`bind=A,B`), and `flk config unset KEY`.

### Fixed

- A non-root `USER` ran as root on busybox-based images (Alpine): the
  agent now switches users when the image's `setpriv` can't.
- `flk volumes backups` listed copies at `backup_copy_to` that a prune
  had deleted. Pruned copies carry `pruned_at` in `--json`.

### On the host

- Nothing to run. The `USER` fix reaches an app at its next deploy.

## 0.3.0 (2026-11-05, commit fbfbe93)

Reliability: every bug the real apps reported in their `BUGS.flk.md`.

### Added

- Every build is logged per release, and a failed build prints what the
  build said first. `flk releases --json` has `build_log`, and the
  `deploy.failed` event has `log`.
- flk's images carry the labels `flk.app` and `flk.release`, and
  `flk images prune` removes the ones no release uses.
- `flk deploy --no-backup` skips the `before_deploy` backups. The
  `[flk.backup] verify` hook gets `FLK_BACKUP_REASON`.
- Help topics: `flk help dockerfile`, `flk help host`, `flk help bugs`.
  The guide lists every variable the guest gets.

### Fixed

- A restart of `flk-tmux.service` (an unattended upgrade did one)
  stopped every machine and nothing started them again. The unit now
  resumes them.
- Root filesystem builds worked in `/tmp`, which can be a RAM disk. They
  work next to their output, stream the export, and check free space
  first.
- Any `http` check crashed the deploy.
- A `log` check ending in `$` never matched.
- A new volume stayed root's when the image had no mount point for it.
  It takes the image's `USER`.
- An Alpine image with a `USER` died at boot (its `setpriv` has no
  `--reuid`).
- `flk exec` right after a boot crashed with a backtrace. It waits for
  the agent.
- A failed `before_deploy` verify blocked the deploy that would fix a
  broken first release, and a failed `before_deploy` backup left the
  machine stopped.
- Every start and deploy of an app with a UDP `internal_port` waited 30
  seconds for a TCP listener.
- `before_deploy` backups weren't copied to `backup_copy_to`.
- A machine whose root disk file is missing is given a new one from its
  release image at start.

### On the host

- `sudo ./setup-host.sh --install-service` once more, for the
  `flk-tmux.service` that resumes machines. `flk doctor` warns about the
  old unit.

## 0.2.0 (2026-10-16, commit 6958961)

Safer deploys, backups you can trust, files, events, exec, names between
apps, and a first install that leads the way.

### Added

- Deploys wait for health checks (`[checks]`, fly's service checks, and
  flk's `type = "log"`). A machine that fails goes back to its previous
  release, and the release is marked failed.
- `flk releases rollback [vN]`, and `[flk] keep_releases`.
- flk.toml typos warn, with a suggestion. `flk context` carries the
  warnings.
- `[[vm]] huge_pages = "2M"`.
- Backups:
  - `flk volumes verify`, and `flk volumes restore --as NEW` to restore
    next to the live volume.
  - Copies to another disk or host: `backup_copy_to`, and
    `flk volumes copy`.
  - Space checks before a backup, and in `flk doctor` and `flk disk`.
  - `[flk.backup] before_deploy = true`: a failed deploy restores the
    volumes too, and `flk releases rollback --with-volumes`.
  - `flk volumes move VOL --to DIR`.
  - `flk apps destroy --with-backups`, and `flk apps prune --backups`.
- `flk files ls|cat|cp|rm|mkdir|chown`: a volume's files, or a backup's,
  without root and without mounting.
- `flk events [--follow] [--json]`: a history of what happened.
- `flk exec` and `flk ssh console`: commands and a shell in a running
  machine, through flk's agent over vsock.
- Images without `/bin/sh` (distroless, scratch) boot, with a static
  init.
- `[flk] internal_hosts = true`: `APP.internal` names between machines.
  Machine JSON has `internal_names`.
- `flk stop`, `flk start` and `flk restart` for a whole app.
- `flk volumes create --owner UID:GID`.
- `flk config set` and `flk config show --host` for host settings.
- Install: `flk-sanity.sh` lists every step in order, and
  `flk setup --fix` adds the PATH link and podman's short names.
- `flk-tmux.service` owns flk's tmux server, and
  `setup-host.sh --install-service` runs the whole host setup in one
  root command.

### Fixed

- Backups no longer push the host's page cache out.
- A failed build or deploy says that nothing changed.
- Fedora and RHEL images failed to build (files with mode 0000), and a
  root filesystem lost its file capabilities.
- After a reboot, a start that lost a race could kill the machine that
  won it.

### On the host

- `sudo ./setup-host.sh --install-service` once more, for
  `flk-tmux.service`.
- `flk exec` needs Go to build the agent, and works in releases built
  since.

## 0.1.0 (2026-10-12, commit 6183c62)

The base: fly.io's workflow on one host.

- `flk launch`, `flk deploy`, `flk status`, `flk logs`, `flk console`,
  `flk machine`, `flk scale count`, `flk volumes`, `flk secrets`,
  `flk releases` and `flk proxy`, reading `flk.toml` or an unchanged
  `fly.toml`.
- Each machine is a Firecracker microVM on flk's own tmux server, with
  volumes as ext4 files and secrets on a config drive.
- `[[services.ports]]` and `[flk] http_port` forward host ports, with a
  guard for ports the host uses. A host `address`, and `bind` to forward
  on chosen addresses only.
- Reboots: machines record what should run. `flk resume`,
  `flk stop-all`, and `flk-machines.service` at boot and shutdown.
- `[[restart]]` policy `on-failure`, `always` or `never`, with retries
  and backoff. A machine that exits on its own is noticed at once.
- A stop is graceful: the app gets SIGTERM and `kill_timeout`, and its
  volumes are unmounted cleanly.
- Volume backups: `flk volumes backup` (stop, live or pause, with
  hooks), `backups`, `restore` and `extend`. Volumes outside flk's state
  directory (`--path`, `--from-dir`, `import`).
- A CLI that explains itself: one command table behind all parsing and
  help, `flk context`, `flk help --all [--json]`, `--json` on listing
  commands, `Next:` lines, guides by stage, bash completion, and
  `flk doctor [--json]`.
- For tools (lazyflk): `flk console --send TEXT [--wait-log REGEX]`,
  `-a APP` from anywhere, `flk machine stats`, `flk disk`,
  `flk images`, `"schema"` in the JSON, and read commands that never
  wait on flk's lock.
- `console.log` rotates to `console.log.1` past `FLK_LOG_MAX_MB`.
