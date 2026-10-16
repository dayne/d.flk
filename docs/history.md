# flk history

What's done, and the decisions behind it, moved out of `TODO.md` and
`PLAN.md` on 2026-10-15 so those list only open work. Kept for context:
why something is the way it is, and the JSON lazyflk was promised (the
G numbers lazyflk's docs refer to). Newer work is in `git log`.

## Decisions still in force

- **No forwarded ports on 127.0.0.1** (2026-10-14). It needs
  `route_localnet`, a host-wide security trade-off; use the host's LAN IP,
  or `flk proxy` for TCP. Nothing covers UDP on loopback.
- **`APP.internal` is a hosts file, not a DNS server** (2026-10-14): no
  daemon, no root step, opt-in (`[flk] internal_hosts`).
- **`flk exec` / `ssh console` run as root by default** (2026-10-14), as
  `fly ssh console` does; `--user` for the app's user.
- **flk's tmux server keeps the Ctrl-b prefix** (2026-10-14); `flk
  console` inside tmux prints the `Ctrl-b Ctrl-b d` hint.
- **No transparent huge pages**: Firecracker's "Transparent" mode left
  guest memory without THP here, so only `huge_pages = "2M"` is offered.
- **Build containers left by an interrupted build are never removed by
  flk** (another build's look the same); it prints the `buildah rm`.
- **lazyflk's API is flk's CLI and JSON**: changes are additive; a
  rename, removal or type change bumps `"schema"`.

## Milestones (from PLAN.md)

### M1: Backups you can trust (done 2026-10-13: 4ff9e9b, a04fcc6, 4b26b65, 1bdb910, 3f618a4, 63db57f)

1. **`flk volumes restore --as NAME`** restores a backup into a new
   volume (or `--path`) next to the live one. Nothing stops and nothing
   is replaced. `flk volumes backup --verify ID` runs e2fsck and an
   optional `[flk.backup] verify` hook against a copy.
2. **Copies elsewhere**: host `backup_copy_to = "/mnt/disk" |
   "user@host:/path"` and `copy_keep`.
   - After a backup, flk copies the newest one with rsync (`--sparse`,
     with resume).
   - `flk volumes backups` shows where each copy is.
   - Doctor warns when the last copy is old.
   - It's opt-in: nothing happens without the setting.
3. **Space checks**: before a backup, estimate whether it fits in
   `backup_dir` (`keep` × the size used) and refuse early. Doctor warns
   when space is tight. `flk disk` shows the backups per volume.
4. **Volume rollback (opt-in)**: `[flk.backup] before_deploy = true`
   backs up before a deploy's roll. A failed health check restores that
   backup before the old release boots. Releases record the backup ID,
   so `releases rollback --with-volumes` can do the same later.
5. **Reflink-aware moves**: `flk volumes move VOL --to DIR` (machine
   stopped, sparse copy). Doctor gives a hint when volumes and backups
   are on a filesystem with reflinks (XFS, btrfs), since copies are then
   instant.

### M2: Volume files without root (done 2026-10-13: `flk files`)

- `flk volumes ls|cat|cp|rm|mkdir|chown VOL PATH`, built on `debugfs -w`
  (no mount, no sudo). Each also works on a backup (`--backup ID`, read
  only).
- flk refuses writes while a machine has the volume attached.
- `cp` sets uid/gid (`--owner`, defaulting to the parent's owner).
- Every write ends with an e2fsck.

### M3: Talk to running machines (done 2026-10-13: events c0a98f4, exec 25b23ad, static init)

- **G7 events**: `flk events [--json] [--follow] [-a APP]`. An
  append-only, rotated `events.jsonl`, fed by lifecycle commands and the
  exit hook. It covers start, stop, exit, restart, give-up, deploy,
  rollback, check results, backups and port changes. lazyflk can then
  stop polling.
- **Exec over vsock**: a small static agent in the guest, started by
  `/flk/init`.
  - `flk exec ID -- CMD` keeps the exit code, stdout and stderr apart.
  - `flk ssh console` gives a real shell.
  - Live backups can use it to sync/fsfreeze in the guest.
- **Static init** (same toolchain): distroless/scratch images boot.

### M4: Networking between apps (done 2026-10-14)

- **`APP.internal` names**: `[flk] internal_hosts = true` puts
  `APP.internal` / `ID.vm.APP.internal` in the guest's `/etc/hosts`, at
  boot and kept current through flk-agent. Decided (Dayne, 2026-10-14):
  a hosts file, not a DNS server (dnsmasq or flk's own): no daemon, no
  root step, and opt-in so apps that don't ask are untouched.
- **Ports on 127.0.0.1**: not doing (Dayne, 2026-10-14). `route_localnet`
  is a host-wide security trade-off; `flk proxy` covers TCP, and the
  host's LAN IP works for everything.

### First install (done 2026-10-15: PR #1, PR #2)

- `flk-sanity.sh` lists every step in order; `flk setup` checks packages
  before downloading, and `--fix` adds the PATH link and podman's short
  names; doctor puts optional warnings after "Ready to fly";
  `setup-host.sh` says what it set up and what's next.
- `flk config set` / `config show --host` for host settings.
- Tests 60/61 install on fresh Ubuntu and Arch VMs.

## Done, by area (from TODO.md)

### Setup and host checks

- [x] **First install, end to end** (PR #1 21ffec9, PR #2, 2026-10-15).
  `flk-sanity.sh` lists every step in order; `flk setup` stops before the
  download when a package is missing, and `--fix` (or a prompt, in a
  terminal) adds the `~/.local/bin/flk` link and podman's short names,
  before doctor runs; doctor prints optional warnings after "Ready to
  fly"; `setup-host.sh` ends with what it set up and the next step (the
  kvm log-out only when it added the user, `--install-service` when the
  boot service is missing); `flk config set` for host settings; the guide
  and README start at `git clone`. Tests 60/61 install on fresh Ubuntu and
  Arch VMs.

### Reliability

- [x] **Forwarded ports on 127.0.0.1** (decided 2026-10-14: won't do; use
  the LAN IP or `flk proxy`) (from the bug report, optional part):
  loopback is skipped on purpose; making it work needs `route_localnet`
  on the bridge path, a host-wide security trade-off. `flk proxy` covers
  TCP; nothing covers UDP yet.
- [x] **Deploys wait for health checks** (`[checks]`, fly's service/http_service
  checks, flk's `type = "log"`); a failing machine goes back to its
  previous release, the release is marked failed, the roll stops.

### Config and releases

- [x] **flk.toml typos warn** (`deploy`, `config show` warnings), with
  did-you-mean, against flk's keys and the fly.toml keys it knows.
- [x] **`flk releases rollback [vN]`**: a new release from an old one's image
  and recorded machine config; `[flk] keep_releases` (default 2).

### lazyflk gaps (G4–G14; G1–G3 are under Earlier, G15–G16 in git log)

- [x] **G5: context always runs doctor (cheap polling).** lazyflk polls
  `flk context --all --json` every 5s, and each call runs all 15 doctor
  checks (podman, `sudo -n -l`, systemctl...). Add `--no-host` to
  `context`: same JSON, but `host` is just `{ "lan_ip": ... }` and
  `next_steps` has only the per-app ones. lazyflk then runs
  `doctor --json` separately every 30s (it already does for the Health
  tab) and merges. Test: `--no-host` output has the same `apps` as
  without it, and runs no `sudo`/`systemctl`.
  Done: `context [--all] --json --no-host`; `host` is `{ "lan_ip" }`, no
  sudo/systemctl/podman calls (tested), 0.09s vs 0.44s here.
- [x] **G6: JSON has no schema version.** Add top-level `"schema": 1` to
  `context --json`, `context --all --json`, `help --all --json` and
  `doctor --json`. Rule (put it in `share/guide.md`): adding fields keeps
  the number; renaming, removing or changing a field's type bumps it.
  lazyflk will show "flk is newer than this lazyflk" on a higher number.
  Done: `"schema": 1` in all four; the rule is in the guide (`help --all`).
- [x] **G4: no per-machine CPU/memory.** For the machine Overview. Add
  `pid` (firecracker's, null when stopped) to machine JSON, and
  `flk machine stats [ID...] --json` → array of `{ "id", "cpu_percent",
  "rss_mb", "memory_mb" (configured), "uptime_s" }` from /proc of the
  firecracker process (cpu over a ~0.5s sample, or since the last call).
  Without an app (`flk machine stats --all --json`) for every machine, so
  lazyflk makes one call per refresh.
  Done: `pid` in machine JSON; `flk machine stats [ID...] [--all] [--json]`
  → `{ app, id, name, state, pid, cpus, memory_mb, cpu_percent, rss_mb,
  uptime_s }` (nulls when stopped); one 0.5s sample for all machines.
- [x] **G8: no disk breakdown.** When a disk fills, show what flk uses.
  `flk disk --json` → `{ "state_dir", "apps": [ { "app", "images" (release
  rootfs), "rootfs" (machine copies), "volumes", "logs" } ], "backups" }`,
  each `{ "bytes" (allocated, sparse-aware), "apparent" }`, plus totals.
  lazyflk shows it in the host Disk tab next to `df`.
  Done: `flk disk --json` → `{ state_dir: { path, bytes, apparent }, apps:
  [ { app, images, rootfs, volumes, logs, external_volumes, total } ],
  totals: { images, rootfs, volumes, logs, external_volumes }, backups:
  { dir, bytes, apparent, apps: { APP: {...} } } | null }`; each size is
  `{ bytes, apparent }`; `total` is what the app takes in the state dir.
- [x] **G9: no status of flk's systemd units (host Services tab).** doctor
  says whether the boot service is installed, not whether `flk-net` and
  `flk-machines` are running or failed. Add to `doctor --json` (or a
  `"services"` key in `context --all --json`): `[ { "unit":
  "flk-net.service", "installed", "enabled", "active" ("active",
  "failed", ...), "since" } ]` from `systemctl show` (no root needed).
  A failed unit should also be a doctor warn with `journalctl -u UNIT`
  as the hint.
  Done: `doctor --json` `services` (and `context --all --json`
  `host.services`): `{ unit, installed, enabled, active, sub, result, since }`;
  a failed unit is a warn with the journalctl hint.
- [x] **G10: no list of flk's images (host Images tab).** `apps prune`
  knows about orphaned images, but nothing lists them. `flk images
  --json` → `[ { "repo", "tag", "app", "release", "in_use" (a machine runs
  it), "orphan" (app destroyed), "size_bytes", "created_at" } ]` from
  podman/docker. Stays read-only; pruning is `apps prune`.
  Done: `flk images [--json]` → `{ repo, tag, id, size_bytes, created_at,
  app, release, orphan, current, in_use, running }`, one per tag.
- [x] **G11: config warnings in context.** lazyflk polls context, so each
  app there (`context` and `context --all`) has `"config_warnings"`: the
  `config show` warnings for its recorded flk.toml, `[]` when clean or
  unreadable. Text context prints them as `⚠ flk.toml: …` lines,
  and each is a next step: `optional: flk.toml: unknown key K (did you mean
  K2?); flk ignores it` (`APP: ` in front with `--all`). Also: a machine
  left on a failed release by `deploy --no-rollback` gets `machine ID [NAME]
  is on vN, which failed its health checks (left by --no-rollback): see flk
  logs -i ID --no-tail; then flk releases rollback, or fix and flk deploy`
  instead of "older release" (the step names the version: `flk releases
  rollback vN`, the current one). Plain `flk releases rollback` also goes
  back to the current release then, not the one before it.
- [x] **G7: no events.** Done (PLAN.md M3): `flk events [--all] [-f] [--since T] [-n N] [--json]`; types in `Events::TYPES` and the guide. `flk events --json --follow [--since TS] [-a APP]`,
  one object per line: `{ "at", "app", "machine", "type", "release"?,
  "detail"? }`. `type` is a fixed set, documented in the guide. `--since`
  lets lazyflk reconnect after a gap. Fed by the exit hook and lifecycle
  commands. lazyflk keeps polling slowly while the stream is alive.
- [x] **G12: JSON for PLAN.md M1/M2** (lazyflk-3a, 2026-10-13). Done in
  lazyflk 2026-10-14: verified_at/verify/copies (529c1df), release backups
  and rollback --with-volumes (d4cb33b), disk backups per volume (9e8b68c),
  volumes move (d4cb33b), files ls --json (545a1b5). Was: message it
  for each feature as it lands, with the commit and the JSON shape:
  - `volumes backups --json`: per backup `verified_at`, `verify`
    ("clean" / "errors" / the hook result), and `copies: [{ "to", "at",
    "ok" }]`.
  - Releases: `backup` (the before_deploy backup ID);
    `releases rollback --with-volumes`.
  - `flk disk --json`: backup bytes per volume.
  - `volumes move`: an ordinary command (lazyflk makes a form for it).
  - `volumes ls --json`: `{ name, type, size, uid, gid, mode, mtime }`,
    on a volume and on a backup (lazyflk's read-only file browser).
- [x] **G13: a failed build or deploy says nothing changed** (lazyflk
  d-lazyflk-a9, 2026-10-14; the opencode.flk entry "A failed build doesn't
  say nothing changed" below). lazyflk shows flk's output in its job view
  and wants the last lines stable enough to show as the result. Additive:
  - stderr ends `Error: build failed; machines unchanged (still on vN)`
    (or the checks equivalent), then a `Next:` line.
  - An event: type `deploy_failed`, `release` = the unchanged current one,
    `detail` = `"build"` or `"checks"`.
  lazyflk shows the `Next:` line under a failed deploy, and the event in
  its Events tabs.
  Done: stderr ends `Error: build failed; machines unchanged (still on vN)`
  (`deploy failed; ...` for a check after the build, `no machines yet`
  before the first deploy), then `Next:`. Health-check failures end with a
  `Next:` too. The event is the existing type `deploy.failed` (types use
  dots), `release` = the current one, `detail` starting with the same
  "build failed; machines unchanged" text; a check failure during the roll
  keeps `release` = the new one and `detail` "vN failed its health checks".
- [x] **G14: `flk volumes create --owner UID:GID`** (lazyflk d-lazyflk-a9,
  2026-10-14; the opencode.flk entry "A new volume's root is owned by root"
  below). lazyflk's create form adds an owner field when
  `help --all --json` lists the option, so no schema bump. If flk instead
  defaults the root to the image's USER, put the root's `uid`/`gid` in
  `volumes list --json` so lazyflk can show it.
  Also from lazyflk: its exec form is adding a "user" field
  (`flk exec --user`), so changing exec's default user later is fine.
  Done: `--owner UID[:GID]` (in help --all --json), and both: a volume
  created without --owner/--from-dir has `owner_from_image: true` in
  `volumes list --json` until its first use, when its root takes the owner
  of the mount point in the image (then the field goes). No root uid/gid in
  `volumes list` (it'd need a debugfs per volume per poll).

### From opencode.flk (first app by hand, 2026-10-13)

- [x] **A new volume's root is owned by root** (done: G14), so an image with a non-root
  `USER` can't write to its mount point: the Dockerfile's
  `chown developer /workspace` is hidden by the mount. (vintagestory.flk hit
  the same and fixed it with `flk files chown`.) Idea: `flk volumes create
  --owner UID:GID`, and/or default a new, empty volume's root to the image's
  USER the first time it's mounted (init, or at deploy from the image config).
- [x] **No app-level stop/start** (done: `flk stop|start|restart`; `machine
  stop` without an ID lists the machines and does nothing). `flk stop` was an unknown command and
  `flk machine stop` needs IDs. Ideas: `flk stop|start|restart` for all of
  the app's machines (fly has `fly machine stop` but people type `stop`), or
  at least did-you-mean `machine stop` for `stop`/`start`/`restart`, and
  `machine stop` with no ID listing the app's machines (or acting on the
  only one).
- [x] **A failed build doesn't say nothing changed** (done: G13). It ended with podman's
  error; the person stopped the running machine thinking the deploy had
  touched it. End a build failure with "machines unchanged (still on vN)"
  and a Next: line.
- [x] **Gotcha for the troubleshoot guide** (done: in the guide, and a
  build hint on "GID already exists" / "UID is not unique"): `ubuntu:24.04` (and 23.04+)
  ships user `ubuntu` with UID/GID 1000, so `groupadd -g 1000` fails. Use
  `usermod -l NEW ubuntu && groupmod -n NEW ubuntu` (and move its home), or
  `userdel -r ubuntu` first. flk could recognize "GID '1000' already exists"
  in build output and print that hint.
- [x] `flk exec`/`ssh console` default to root; an image with a `USER` might
  expect that user (`--user developer` works). Considered defaulting to the
  image's USER, like `docker exec`; decided (2026-10-14) to keep root, as
  `fly ssh console` does: exec is an admin and agent tool, and agents run
  admin commands through it. Scripts that want the app's user pass
  `--user` (opencode.flk's ssh-dev does).

### LAN addresses

- [x] **Advertised address** (`address` in `~/.config/flk/host.toml`; doctor
  checks it's on this host) and **forwarding on chosen addresses**
  (`[flk] bind` per app, `bind` per host; nft map `addr_ports` keyed by
  address, tried before the any-address map; the helper checks listeners
  per address). Tested for real in a private network namespace
  (tests/cases/06-ports-netns.sh). An old helper keeps forwarding on every
  address rather than dropping ports.

### Builds

- [x] **Interrupted builds**: `--force-rm`; on Ctrl-C/failure flk prints
  the `buildah rm` for the build containers it left (never removes them
  itself: another build's look the same); doctor warns about ones older
  than an hour.

### Bigger features

- [x] **Exec into a machine** (PLAN.md M3): `agent/` (Go, stdlib, static)
  is built by `flk setup` / deploy into STATE/bin/flk-agent and baked into
  each release as /flk/agent, started by /flk/init; machines get a vsock
  (`v.sock`). `flk exec [-i ID] [--user U] [--cwd D] [-t] [--stdin]
  [--timeout S] -- CMD` (status, stdout/stderr apart) and `flk ssh console
  [ID] [-C CMD]` (a shell with a pty; `--send` still types on the serial
  console). Releases built before need a redeploy; no Go means no agent
  (doctor says so).
- [x] **`APP.internal` names** between machines (PLAN.md M4):
  `[flk] internal_hosts = true` writes `IP APP.internal ID.vm.APP.internal
  NAME.vm.APP.internal` lines for every machine on the host into the
  guest's `/etc/hosts` (APP.internal only for running ones): on the config
  drive at boot, then rewritten in running guests by a detached
  `flk machine hosts-sync` (flk-agent `hosts`) on every machine event.
  Chosen over dnsmasq: no daemon, no root. Limits: only names (no SRV/TXT,
  no `top1.nearest.of`); live updates need the agent (Go at deploy).
- [x] **Files in a volume without sudo** (PLAN.md M2): `flk files
  ls|cat|cp|rm|mkdir|chown`, `VOL:PATH`, on debugfs. Reads any time (a
  note when the machine runs; `--backup B` reads a backup); writes need the
  machine stopped, take flk's lock, and end with e2fsck -fy. Copied-in files
  get the target dir's owner or `--owner`, local modes; trees and symlinks
  too. `ls --json`: `{ name, type, size, uid, gid, mode, mtime }` (mtime to
  the minute, from debugfs `ls -l`).
- [x] **Backups keep out of the page cache** (minecraft.flk BUGS #9): a
  reflink when the filesystem can; else a sparse Ruby copy (SEEK_DATA/HOLE,
  zero chunks stay holes) at idle I/O priority (normal while the machine
  is stopped or paused for it), synced and `IO#advise(:dontneed)` every
  64MB on both files, and the copy again after e2fsck. Restore too.
  Measured: a 600MB-used image left 1.2G cached with cp, 0 with this.
- [x] **Roll volumes back with the release (opt-in, PLAN.md M1.4).**
  `[flk.backup] before_deploy = true`: deploys and rollbacks back up each
  machine's volumes while it's stopped for the update (reason
  `before_deploy`, `release` = the one it left, `for_release`); the
  release records `backups: [{ machine, volume, volume_id, file }]`. A
  failed health check restores them (in place: no second copy needs room)
  before the old release boots. `flk releases rollback --with-volumes [vN]`
  backs up the current data, then restores vN's before-deploy backups.
  Full copies on ext4 add to deploy downtime; instant on XFS/btrfs.
- [x] `flk volumes move NAME --dir DIR | --path FILE` (PLAN.md M1.5): sparse
  copy + e2fsck -n, then the volume points there; old file deleted if flk's,
  kept if external. Doctor's backup line says whether copies are full
  (ext4) or reflinks (xfs/btrfs).
- [x] **Static init** (PLAN.md M3): an image without `/bin/sh` boots with
  flk-agent as PID 1 (`agent/init.go`, same job and log lines as init.sh,
  reads `/flk/cmd.json`); images with a shell keep init.sh. Test app
  `tests/apps/static` (FROM scratch + /busybox).

### Machines

- [x] **Huge pages** (minecraft.flk BUGS #8): `[[vm]] huge_pages = "2M"`
  → Firecracker's machine-config; deploy (before building) and start
  refuse without enough free pool pages and print the sysctl commands;
  doctor shows the pool; stats count hugetlb pages in rss_mb. Firecracker's
  "Transparent" mode was tried and left guest memory without THP here
  (VMA not advised), so it isn't offered. Not yet seen booting on a real
  pool (needs root to reserve one): tests/cases/45-hugepages.sh runs it
  when a pool exists.
- [x] **`flk console` from inside tmux** (decided 2026-10-14: keep Ctrl-b;
  the hint stays) is now a nested tmux (flk has its own
  tmux server), so detach is `Ctrl-b Ctrl-b d`. flk prints that hint, but a
  different prefix for flk's server would be friendlier.

### Earlier

- [x] Testing backups without downtime (PLAN.md M1.1): `flk volumes verify
  [NAME] [--backup B | --all] [--json]` (e2fsck -n, plus the `[flk.backup]
  verify` hook with `FLK_BACKUP`, which `volumes backup` also runs) records
  `verify`/`verified_at`/`verify_detail` in the backup; `flk volumes restore
  NAME --as NEW [--path FILE]` copies a backup into a new, unattached volume
  (also for a destroyed volume's backups).
- [x] Copies off this disk (PLAN.md M1.2): host `backup_copy_to` (a dir, or
  HOST:DIR over rsync+ssh with keys), `backup_copy_keep`,
  `backup_copy_warn_days`. `volumes backup` copies each new backup there
  (`--no-copy` skips); `flk volumes copy [NAME] [--dest D] [--backup B]
  [--keep N]` by hand, skipping what's there. Each backup records
  `copies: [{ to, at, ok, seconds, error? }]`; doctor warns about stale ones.
- [x] Backup space (PLAN.md M1.3): a backup that doesn't fit prunes the
  backups it would push past `keep` first (keep >= 2), else refuses with
  what's there; it warns when `keep` copies won't fit. Doctor estimates all
  volumes at their keep counts. `flk disk --json` has
  `backups.apps.APP.volumes.VOL = { bytes, apparent, count }`.
- [x] Backups of destroyed apps stay (restore with `--as` after relaunching);
  `apps destroy --with-backups` deletes them with the app, `apps prune
  --backups [--to DIR]` deletes those of apps that are gone (only dirs that
  hold nothing but flk's backup files). Plain `apps prune` mentions them.
- [x] Graceful stop: `/flk/init` now disables the kernel's Ctrl-Alt-Del hard
  reboot, so stop sends the app SIGTERM instead of pulling the plug.
- [x] Guest kernel lookup for Firecracker ≥ v1.16: CI moved to dated
  `firecracker-ci/YYYYMMDD-*` dirs.
- [x] Firecracker runs on flk's own tmux server (`tmux -L flk`), not the user's.
- [x] `kill_timeout` honoured; `[[services.ports]]` forwarded to the host.
- [x] Host port guard: ports below `FLK_MIN_PORT` (default 1024) and ports a
  host process listens on (non-loopback) are refused, in flk *and* in the
  root helper. `flk ports` shows them as blocked.
- [x] Machines that exit on their own are reaped by the listing commands, and
  their host ports are handed to the next machine or dropped.
- [x] Tests forward a random free host port instead of 25565.
- [x] `kill_timeout` capped at 300s (config rejects more; stop clamps old
  machines' stored value).
- [x] Agent-friendly CLI: one command table drives argument parsing (unknown
  options/arguments are errors, with did-you-mean) and all help: `flk help`,
  `flk help CMD`, `flk CMD --help`, `flk help --all [--json]`. `flk context`
  shows the current state with next steps. `--json` on listing commands.
  `logs` follows only in a terminal; `apps destroy` and `console` never wait
  on a missing terminal.
- [x] Podman short image names: `flk doctor` / `flk context` warn when podman
  has no search registries, and a build or pull that fails with
  "short-name ... did not resolve" prints the fix: a user-level drop-in
  (`~/.config/containers/registries.conf.d/`, which adds to the system config
  instead of replacing it), or the full image name.
- [x] Restart policy: `[[restart]] policy = on-failure (default) | always |
  never`, `retries` (10), backoff 1s..60s, reset after 10 minutes up or a
  manual start; gives up visibly (log, context). flk marks machines it's
  stopping so its own stops are never taken for crashes (that race was real:
  1 in 3 stops). Tests run on their own tmux server, so they never repoint
  the real exit hook, and doctor checks the hook's flk exists.
- [x] The tmux exit hook always runs the boot service's flk (from
  flk-machines.service) when that's installed, so flk run from a worktree
  or a manual test can't repoint it (it did once: a manual deploy from a
  worktree); doctor warns when it points anywhere else.
- [x] Volume backups: `flk volumes backup` (stop / live / pause modes,
  `[flk.backup]` pre/post hooks as host commands or console lines with a
  log wait, e2fsck of each copy, `keep` pruning), `backups`, `restore`
  (keeps the replaced image), `extend`. Host settings in
  `~/.config/flk/host.toml` (`backup_dir`, `backup_keep`). Guests write
  cached data within ~1s and volumes commit every 1s, so a live copy a few
  seconds after a flush holds it.
- [x] New volumes on another disk no longer ask for `--install-service`:
  a plain /etc/fstab mount is already ordered before the boot service
  (local-fs.target); doctor only warns for nofail, network or hand-made
  mounts. A machine whose volume file is missing won't start (clear error).
- [x] lazyflk gaps G1-G3: read commands never wait on flk's lock (they skip
  the reap when busy); flk records each app's config path so `-a APP`
  works from anywhere (`config_path` in JSON); `flk console --send TEXT
  [--wait-log REGEX] [--timeout S]` talks to the app without attaching.
- [x] Admin help at every stage: `flk context --all` (host overview),
  `flk help TOPIC` guides (cheatsheet, install, first-app, operate,
  troubleshoot, uninstall; also in `help --all`), `Next:` lines after
  commands that change things, `flk completion bash`, and absolute paths
  to `setup-host.sh` in every hint.
- [x] From the minecraft.flk bug report: `/dev/fd`, `/dev/std*` in the guest;
  the app's stdin is the serial console (`[flk] stdin = "null"` to opt out);
  volumes with `--path` / `--from-dir` / `import` that flk never deletes;
  forwarded ports say they don't answer on 127.0.0.1 and show the address
  that does.
- [x] From the bug report, part 2: a stop unmounts volumes and remounts the
  rootfs read-only before the guest reboots (no journal replay; host tools
  see a clean volume). `flk-machines.service` gets `RequiresMountsFor=` the
  state dir and every external volume's dir; doctor warns when a volume's
  disk isn't covered. Volumes outside the state dir count as external even
  without the flag (a hand-edited path is never deleted).
- [x] No more image and log leaks: release pruning and `apps destroy` untag
  `flk.local/APP:vN`; `flk apps prune` clears tags of apps already gone
  (doctor warns about them); `console.log` rotates to `console.log.1` past
  `FLK_LOG_MAX_MB` (libexec/flk-logpipe).
- [x] Reboots: machines record `desired_state`; `flk resume` starts what should
  run, `flk stop-all` stops everything gracefully and keeps it marked;
  `--install-service` adds `flk-machines.service` (resume at boot, stop-all
  at shutdown); doctor warns when it's missing.
- [x] Machines that exit on their own are noticed immediately: a
  `session-closed` hook on flk's tmux server runs `flk ports reap` (no
  daemon); `exit-empty off` keeps the server alive for it.
- [x] `[flk] http_port = N` forwards `[http_service] internal_port` to host
  port N, with the same guard as `[[services.ports]]`; duplicate host ports
  in one config are rejected.
- [x] Deploy checks volumes and free taps before building, and again under
  the lock before recording the release; a deploy that fails before then
  leaves no release and no image behind. `scale count` checks first too.
- [x] `flk doctor --json`; `flk-sanity.sh` reads that instead of ✔/✘ lines.
  Doctor also reports the port helper (missing / needs a password /
  predates the host port guard) as a warning.
