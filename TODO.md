# TODO

Known rough edges, found while getting flk running on real hardware.
Each entry says where the issue is caught today, and where a fix could go.
The order of work (milestones) is in `PLAN.md`.

## Setup and host checks

- [ ] **Firewall and distro paths are untested on real hosts.** Only Ubuntu
  with Docker's firewall rules has been run end to end. These were written
  blind and need one pass each on a real host:
  - **ufw** (Ubuntu with `sudo ufw enable`): `setup-host.sh` adds
    `ufw route allow in on flkbr0` / `out on flkbr0` rules (`firewall_allow`);
    `flk-sanity.sh` checks them (`check_ufw`).
  - **firewalld** (Fedora default): `setup-host.sh` puts the bridge in the
    `trusted` zone; `flk-sanity.sh` checks it (`check_firewalld`).
  - **dnf / pacman package names**: the install commands `flk-sanity.sh`
    suggests on Fedora and Arch (the `PKG` table) have never been run.
  - *How to test:* on each host, start from a clean install, run
    `./flk-sanity.sh` and run the install command it suggests, then
    `sudo ./setup-host.sh`, `flk setup`, and `tests/run.sh`.
    What to look for: the VMs get network (the `test_guest_egress_nat_and_dns`
    and `test_reachable_on_host_lan_ip` tests), the forwarded ports work
    with the firewall on, `sudo ./setup-host.sh --down` removes the
    rules it added (`firewall_remove`), and sanity's checks pass or point at the right fix.
  - *Suggested hosts:* Fedora (covers firewalld and dnf), Arch (pacman), and
    Ubuntu with ufw enabled.
  - *Symptom if broken:* machines boot but have no network (another
    firewall's FORWARD drop wins over flk's nft accept), or forwarded host
    ports time out.

## Reliability

- [ ] **Forwarded ports on 127.0.0.1** (from the bug report, optional part):
  loopback is skipped on purpose; making it work needs `route_localnet`
  on the bridge path, a host-wide security trade-off. `flk proxy` covers
  TCP; nothing covers UDP yet.
- [x] **Deploys wait for health checks** (`[checks]`, fly's service/http_service
  checks, flk's `type = "log"`); a failing machine goes back to its
  previous release, the release is marked failed, the roll stops.
## Config and releases

- [x] **flk.toml typos warn** (`deploy`, `config show` warnings), with
  did-you-mean, against flk's keys and the fly.toml keys it knows.
- [x] **`flk releases rollback [vN]`**: a new release from an old one's image
  and recorded machine config; `[flk] keep_releases` (default 2).
## For lazyflk (TUI, spec in lazyflk/SPEC.md section 9)

lazyflk only uses flk's CLI, so these are flk changes. M1–M3 are done
(G1–G3 landed); these unblock M4. In order of need. Every new JSON field
is additive: lazyflk ignores unknown fields and treats missing ones as
"not supported by this flk", so nothing existing may change shape.

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
- [ ] **G7: no events.** Later, after the above: `flk events --json`, one
  line per state change (fed by the tmux exit hook and lifecycle
  commands), so lazyflk can stop polling.

## LAN addresses and failover

Today forwarded ports answer on every address the host owns (the DNAT
rule matches `fib daddr type local`), so a second address added with
netplan (e.g. 10.47.11.3 next to the DHCP one) works with no flk change.
To consider:

- [x] **Advertised address** (`address` in `~/.config/flk/host.toml`; doctor
  checks it's on this host) and **forwarding on chosen addresses**
  (`[flk] bind` per app, `bind` per host; nft map `addr_ports` keyed by
  address, tried before the any-address map; the helper checks listeners
  per address). Tested for real in a private network namespace
  (tests/cases/06-ports-netns.sh). An old helper keeps forwarding on every
  address rather than dropping ports.
- [ ] **Managed extra addresses.** Instead of hand-editing netplan, flk-net
  could add/remove listed LAN addresses (`ip addr add ... ` + gratuitous
  ARP) from a root-owned config; doctor checks nobody else answers ARP for
  them (`arping -D`) and that they're outside the DHCP pool (warn only).
- [ ] **keepalived (VRRP) hooks.** A floating address held by the active
  host: `flk host activate` / `flk host deactivate` (resume or stop-all
  the apps tied to that address) for keepalived's notify scripts, and
  `flk host check --address IP` as its health check (machines running,
  ports mapped). A sample keepalived.conf in `share/help/`.
- [ ] **Data for failover.** The hard part: the standby needs the volumes.
  Steps: copy volumes on a clean stop (`flk volumes sync --to HOST`,
  rsync of the stopped sparse file), then maybe DRBD or shared storage.
  Must make split brain impossible: never start an app whose volume
  another host may hold (a lease/fence, or refuse unless this host holds
  the floating address).

## Builds

- [x] **Interrupted builds**: `--force-rm`; on Ctrl-C/failure flk prints
  the `buildah rm` for the build containers it left (never removes them
  itself: another build's look the same); doctor warns about ones older
  than an hour.
## Bigger features

- [ ] **Exec into a machine.** A small vsock agent in the guest for a real
  `flk ssh console` and `flk ssh console -C "cmd"` (like Fly's hallpass).
- [ ] **`APP.internal` DNS** between machines (dnsmasq on the bridge, fed
  from machine records).
- [ ] **Files in a stopped volume without sudo.** `flk volumes ls/cp/rm
  VOL` on top of `debugfs -w` (`write`, `rm`, `rdump`), refusing while a
  machine uses it. Gotcha (from the vintagestory session): `write` creates
  files as uid 0; follow with `sif PATH uid N` / `gid N`. Minecraft's
  `bin/mc-edit` and VS's tooling each do a version of this today.
- [x] **Backups keep out of the page cache** (minecraft.flk BUGS #9): a
  reflink when the filesystem can; else a sparse Ruby copy (SEEK_DATA/HOLE,
  zero chunks stay holes) at idle I/O priority (normal while the machine
  is stopped or paused for it), synced and `IO#advise(:dontneed)` every
  64MB on both files, and the copy again after e2fsck. Restore too.
  Measured: a 600MB-used image left 1.2G cached with cp, 0 with this.
- [ ] **Roll volumes back with the release (opt-in).** Automatic rollback
  restores the image but not the volume, so an upgrade that changed data
  on the volume (VS mods, Minecraft jars) would boot the old image on the
  new data (the vintagestory session's point). Idea: `[flk.backup]
  before_deploy = true` takes a backup before the roll, and a failed
  health check restores it (machine stopped) before booting the old
  release; `releases rollback --with-volumes` could do the same from a
  release's recorded backup. Needs instant snapshots to be cheap for big
  volumes.
- [ ] **Volume snapshots.** Backups and extend are done; instant
  snapshots need volumes on a reflink filesystem (an XFS LV for flk's
  volumes: `cp --reflink` is instant, so `pause` mode freezes the VM for
  milliseconds) or LVM thin volumes (root helper). Then: backups to the
  NAS / a second drive as just another `--to`, or rsync/restic of
  backup_dir; an in-guest `sync`/fsfreeze once exec (vsock) exists.
- [ ] **Snapshots of machines** (Firecracker snapshot/restore): suspend and
  sub-second resume.
- [ ] **Static init** (Go/Rust) so distroless/scratch images boot without `/bin/sh`.

## Machines

- [x] **Huge pages** (minecraft.flk BUGS #8): `[[vm]] huge_pages = "2M"`
  → Firecracker's machine-config; deploy (before building) and start
  refuse without enough free pool pages and print the sysctl commands;
  doctor shows the pool; stats count hugetlb pages in rss_mb. Firecracker's
  "Transparent" mode was tried and left guest memory without THP here
  (VMA not advised), so it isn't offered. Not yet seen booting on a real
  pool (needs root to reserve one): tests/cases/45-hugepages.sh runs it
  when a pool exists.
- [ ] **`flk console` from inside tmux** is now a nested tmux (flk has its own
  tmux server), so detach is `Ctrl-b Ctrl-b d`. flk prints that hint, but a
  different prefix for flk's server would be friendlier.
- [ ] **flk's tmux server keeps its groups.** The server now stays up when idle
  (for the exit hook). If it lacks `kvm` and no machines run, flk restarts it
  by itself; with machines running it still says to stop them and run
  `tmux -L flk kill-server`.

## Done (for reference)

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
