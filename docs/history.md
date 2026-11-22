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

- [x] **Host checks while the host runs** (health-design.md step 3,
  2026-11-22). The checks `flk doctor` makes are run by the timer every
  5 minutes (`flk check --all --due`) and by hand (`flk check --host`);
  each result is kept by the check's new `id` in
  `STATE/host-checks.json`, and `host.problem` / `host.recovered` events
  go out when one changes. The first run takes stock; a new problem is
  looked at twice. Doctor and context still look for themselves and
  write nothing. Two checks were added: room on the disks under flk's
  state and volumes (`disk_warn_percent`, 90) and the age of the newest
  backup of each backed-up volume (`backup_warn_days`, unset = not
  checked, because flk doesn't know the backup schedule). Decided: one
  list (doctor's), not a second set of host checks; a warning is a
  change worth an event but not a failure (`ok` stays true, exit 0).
  Fixed on the way: doctor's tmux-server check counted machines on
  another tmux socket. Details in health-design.md, "As built: host
  checks". Tests (fast, in a throwaway state dir so the real host's
  store and events never hear of them): `05-cli`
  test_host_checks_report_changes, `00-config` test_doctor_json (ids)
  and test_doctor_disk_and_backup_age.
- [x] **Versions and `CHANGELOG.md`** (Dayne, 2026-11-21). flk had said
  0.1.0 since its first commit. `CHANGELOG.md` now lists what changed
  per version for people who run flk and tools that read it (this file
  keeps the reasons), with a "On the host" part for what to run after
  updating. The past was cut into versions afterwards, from this file
  and the git log, at the points where main rested: 0.1.0 (6183c62,
  2026-10-12, the base), 0.2.0 (6958961, 2026-10-16: safer deploys, M1
  to M4, first install), 0.3.0 (fbfbe93, 2026-11-05: R1), 0.4.0
  (2ebd093, 2026-11-11: M6), 0.5.0 (54772bf, 2026-11-17: ssh mount),
  and 0.6.0 (2026-11-21: health while running, `logs --boot`,
  `log_max_mb`), the first one flk reports itself. Each command's first
  version was checked against the command table at those commits.
  Decided: `0.MINOR.PATCH`, MINOR for anything new and PATCH for fixes
  alone; work on main between releases is "Unreleased" and
  `Flk::VERSION` stays at the last release; a release is Dayne's call
  (the rule is in AGENTS.md). Test: `05-cli`
  test_version_matches_the_changelog.

- [x] **Install tests run as a user** (2026-10-15). Tests 60–62 create
  `flkuser` (a password, no NOPASSWD) and run sanity, `flk setup --fix`,
  the PATH and final checks as that user; only package installs and the
  kvm group (what setup-host.sh does) run as root. The kvm step checks all
  three states sanity reports (not in it, added but this login lacks it,
  in it), and nothing may wait for a sudo password. Seen: Ubuntu and
  Fedora put `~/.local/bin` on PATH at login, Arch doesn't (setup's PATH
  line covers it). Found on the way: flk's rootfs dropped file
  capabilities (`setcap`, xattrs tar can't restore without root);
  `flk-build-rootfs` now writes them back with debugfs (`libexec/flk-tar-caps`,
  test `08-rootfs`; checked in a VM: a cap_net_bind_service busybox binds
  :80 as nobody). Sanity's engine check shows podman's error line; its GNU cp check no
  longer fails now and then (`cp --help | grep -q` under pipefail: ~4% on
  one CPU); "flk not on PATH" says to fix PATH when the link is there.
  (`archlinux:latest` and `fedora:latest` themselves lack the caps on
  newuidmap/newgidmap that their shadow packages set, in the registry
  layers too; the test reinstalls the package.)
- [x] **A Fedora install test** (2026-10-15): `tests/cases/62-install-fedora.sh`.
  `tests/install-run.sh` now installs with the command `flk-sanity.sh`
  suggests on every distro, so the apt, pacman and dnf columns of its
  `PKG` table are all run. Found on the way: Fedora's mode-0000
  `/etc/shadow` and `/etc/gshadow` broke every Fedora/RHEL-based image's
  rootfs build (`mkfs.ext4 -d`: Permission denied); `flk-build-rootfs`
  re-applies such modes under fakeroot (test `08-rootfs`). Sanity also
  says "inside a VM" from the CPU's hypervisor flag when there's no
  `systemd-detect-virt`.
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

- [x] **The guest init lost a quick app's exit status** (found
  2026-11-20 by a flaky test, 10-hello
  test_experimental_cmd_and_exit_status). `share/init.sh` asked whether
  the app was alive before waiting for it; an app that had already
  exited and been collected by the shell was never waited for, and init
  logged `app exited with status 0`. Measured on mud: 1 of 60 boots of
  an app that runs `exit 3`. flk reads that line (`last_exit_status`),
  so a crash at start could count as a clean exit, which
  `[[restart]] policy = "on-failure"` doesn't restart. Now `wait_app`
  waits first and looks after, and when a stop signal cut the wait
  short just as the app went, fetches the app's own status. 200 of 200
  boots correct with the first form, 120 of 120 with the final one.
  Test: 05-cli test_init_reports_the_apps_exit_status
  (`tests/lib/waitapp.sh`: the function under dash, bash and busybox,
  with the cases the old loop got wrong). The static init
  (`agent/init.go`) was never affected. A guest change: machines get it
  at their next deploy.
- [x] **Three help topics** (R1, 2026-11-05): `flk help dockerfile`
  (writing a Dockerfile for flk: what a deploy does with it, the guest is
  a VM, the exact env inside, USER and setpriv, volume owners, stopping,
  pinning, readiness), `flk help host` (the three services and what
  restarting each does, upgrades and needrestart, what stops machines,
  disk space and `images prune`, host backups), `flk help bugs` (the
  BUGS.flk.md format, written once). The first was going to be `images`,
  but `flk help images` must stay the command's help. The guide's env
  line lists every variable (M6's "guest env contract").
- [x] **A copy pruned at backup_copy_to isn't listed as there**
  (enshrouded.flk BUGS.flk.md #4, 2026-11-10). `prune_copies` deleted the
  oldest copies but left them in their backups' `copies`, so
  `flk volumes backups` promised copies that were gone. Each copy now
  marks the entries for that destination whose file isn't there any more
  with `pruned_at` (this prune's, and stale ones from before), the table
  leaves them out, and doctor's newest-copy age ignores them. Additive in
  `--json`. Test: `26-backup-tools` test_backup_copies_to_another_disk.
- [x] **before_deploy backups are copied to backup_copy_to** (R1,
  enshrouded.flk BUGS.flk.md #2, 2026-11-04). Only `flk volumes backup`
  copied its new backup; a deploy's own before_deploy backups stayed on
  the backup disk. Now `deploy` and `releases rollback` copy the
  release's before_deploy backups once the roll is over, succeeded or
  not (copying during it would add to the downtime), outside the global
  lock. A failed copy warns (`backup.copy_failed`, and the `flk volumes
  copy --backup FILE` to retry): the deploy is done and the backup fine.
  Test: `42-deploy-volumes` test_before_deploy_backups_are_copied.
- [x] **No TCP wait on a udp internal_port, nor before a deploy's
  checks** (R1, valheim.flk BUGS.flk.md #6, 2026-11-04). `boot` always
  waited 30s for TCP on internal_port: valheim's udp/2456 never answers,
  so every deploy and start lost 30s and printed a false "nothing
  listening" warning before its log check passed at once. machine_config
  now carries `internal_protocol` (`[http_service]` is tcp); boot skips
  the wait for udp (printing a hint toward a log check when there are no
  checks) and, in a deploy, when health checks come right after (create
  and update pass `checks_follow`). Plain start, restart and resume still
  wait on tcp: it's their only readiness report. Tests: `44-boot-wait`
  (new), `00-config` internal_protocol. Also fixed: the tests'
  `port_address` took the host's first forwarded port, enshrouded-flk's
  own address, so `20-mcshadow` failed on this host (on main too).
- [x] **Log checks can end in `$`** (d.flkforge BUGS.flk.md #2,
  2026-11-04). `check_passes?` matched the raw console tail, whose lines
  end in "\r\r\n", so Ruby's `$` (before "\n") never matched after the
  text and such a check timed out. It strips "\r" first, like the shared
  reader behind `console --wait-log` and backup hooks' `wait` already
  did. Test: `05-cli` test_log_check_regex_anchors.
- [x] **A before_deploy verify failure no longer traps a broken app, or
  leaves a working one down** (R1, valheim.flk BUGS.flk.md #5,
  2026-11-04). valheim's v1 never started, so its volume held no world;
  the deploy meant to fix it stopped at the verify hook ("no
  /worlds_local/flktest in the backup") with no way past. Now: the hook
  gets `FLK_BACKUP_REASON` (`backup`, `before_deploy`, `verify`);
  `flk deploy --no-backup` skips the before_deploy backups and the error
  names it; and when the machine's release has status failed (never
  passed its checks), a failed verify warns and the deploy goes on.
  Found on the way: a failed before_deploy backup (any cause) left the
  machine *stopped* on its old release with nothing to start it, and the
  new release looked fine. Now it starts again (if it was running), the
  release is marked failed, and the roll stops. Tests: `42-deploy-volumes`
  (four new).
- [x] **A new volume takes the image's USER when the image has no mount
  point for it** (R1, valheim.flk BUGS.flk.md #4, 2026-11-04). A volume
  from `volumes create` (no --owner) took the owner of the mount point in
  the image, if there was one and it wasn't root's; otherwise it stayed
  root's and the flag went anyway, so valheim's vh-run (USER ubuntu)
  couldn't write /data and fixing the Dockerfile didn't help. Now
  `own_new_volumes` falls back to the image's USER (read from the
  rootfs's /flk/user, names through its /etc/passwd and /etc/group, a
  numeric user without an entry as uid:uid, like init) and says which; a
  USER it can't resolve gets a warning naming `flk files chown`. The flag
  stays while nothing was decided and the volume is still empty (a fixed
  image applies next deploy), and a volume with data is never re-owned.
  No `volumes chown` command: `flk files chown UID:GID VOL:/` does it.
  Found on the way: Alpine 3.20's busybox `setpriv` has no `--reuid`, and
  init used it, so any Alpine image with a USER died at boot; init now
  checks for `--reuid` (falls back to root with the warning, see TODO
  Machines). And `flk exec` right after a boot crashed with a Ruby
  backtrace (ECONNREFUSED while firecracker's socket wasn't listening):
  it now retries in the fresh-boot window, then says to try again.
  Tests: `43-volume-owner` (new), `05-cli` image_user.
- [x] **http health checks work** (d.flkforge BUGS.flk.md #1,
  2026-11-04). Any `[checks.NAME] type = "http"` made `flk deploy` crash
  after boot: inside `module Flk`, `Net::HTTP` resolved to `Flk::Net`
  (model.rb's network constants), so the request raised NameError, and so
  did the `rescue` list (`Net::OpenTimeout`...). Now `::Net`. No real app
  used http checks. Test: `10-hello` turns the app into a busybox-nc web
  server; status 200 deploys, 500 fails its check and rolls back.
- [x] **A restart of flk-tmux.service brings the machines back** (R1,
  mud BUGS.flk.md #6, 2026-11-04). needrestart restarted the unit after an
  apt upgrade (2026-10-26); its ExecStop stop-all stopped every VM and
  nothing started them again. The unit now has a guarded `ExecStartPost`
  that runs `flk resume` only while `flk-machines.service` is active: on
  a restart, never at boot or install (flk-machines resumes them itself
  then, and it's `RemainAfterExit`, so "active" means it already has).
  '-' keeps a failed resume from failing the unit (which would stop
  everything again). `flk doctor` warns about units from before this
  change. Test: `05-cli` renders the units and runs the command with a
  fake systemctl as both boot and restart. Takes effect on a host after
  `sudo setup-host.sh --install-service`.
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

- [x] **`flk config set bind=A,B` and `flk config unset KEY...`** (lazyflk,
  2026-11-11). A comma in `bind`'s value writes a TOML list (one address
  stays a string); `unset` removes keys (one not set is reported, not an
  error). Both replace a list that spans several lines whole, and check the
  result before replacing the file, as set did. Test: `00-config`
  test_config_set_and_unset (set had no test before).
- [x] **`next_steps_detail` in `flk context --json`** (lazyflk, 2026-11-11).
  Beside `next_steps` (the same strings, unchanged), the same steps in the
  same order as `{text, app, machine, kind}`; kind is problem, optional,
  stopped (desired_state stopped), setup, info or ok. Built from one list
  (`CLI::Step`, a String that also carries them), so the two can't drift;
  in `--all` the text has the `APP: ` prefix as before. lazyflk stops
  matching " is stopped;". Tests: `05-cli` test_context_for_a_fresh_app,
  `18-app-verbs`.

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

- [x] **Checks of `type = "disk"`** (health-design.md, 2026-11-22).
  `path` (a directory in the machine, default `/`) and `max_percent`
  (default 90): `df -P -k` in the guest through flk-agent as root; the
  check fails when the filesystem is that full, with how full and how
  much is free in its detail. With an `interval` it is the event before
  a volume or root disk fills up. A check type, so opt-in per app like
  the rest; nothing is run in machines that don't ask. Tests: `00-config`
  test_disk_check_config, `05-cli` test_disk_check_reads_df (coreutils'
  and busybox's df output, canned), `47-checks`
  test_a_full_disk_is_a_failing_check (a 1GB volume filled past 50%).
- [x] **Health while running: `flk check`, `interval`, `flk-check.timer`**
  (enshrouded #3, part 1; PLAN M6's last piece; 2026-11-20). Checks ran
  only during a deploy, so `started` said the VM was alive and nothing
  said whether the app answered; the game repos scraped logs for it.
  Now a check with `interval = "5m"` is tried while the machine runs,
  each machine keeps its last results (`flk status`, `checks` in
  `status --json`), and `check.failed` / `check.recovered` go out once
  per change. `flk check [--all] [--due]` is the whole engine;
  `flk-check.timer` runs it every minute. Decided before: checks report
  and never act (Dayne, 2026-11-11). Decided in the build, all listed
  in `docs/health-design.md` ("As built"): results belong to a boot; a
  failed try is confirmed once after 2s; a failing check is tried every
  minute; "starting" inside the grace period and machines that are
  stopping or paused aren't failures; the log check reads the whole
  boot and stays passed; exit code 2 for a failing check; doctor warns
  only when some check has an interval and nothing runs it. Opt-in
  twice over: an app needs `interval` and a deploy, a host needs the
  timer installed. Tests: `tests/cases/47-checks.sh` (VM: fail, report
  once, recover, a new boot, a stopped machine, the runner's mark),
  00-config test_check_interval, 05-cli test_check_results_and_due and
  the units in test_install_service_units_verify.
- [x] **`[[mounts]] seed = true`** (PLAN M6, 2026-11-11). A volume that's
  empty (nothing but lost+found) when its machine is about to boot is
  filled with what the release's image has at the mount point, as Docker
  fills a new named volume: `seed_new_volumes`, before `own_new_volumes`,
  on create, deploy and rollback (the machine is stopped then; a running
  one's volume can't be read from the host). `VolFS.seed!` needs no root:
  debugfs `rdump` copies the tree out under fakeroot, which remembers the
  owners, `mkfs.ext4 -d` makes the volume again from it next to the old
  file, e2fsck, then a rename, so a failure leaves the empty volume as it
  was. The volume's root gets the directory's own owner and mode (mkfs
  leaves it root's), and `owner_from_image` is settled. Not kept: setuid
  bits, hard links, devices; a symlink gets its directory's owner (rdump
  doesn't chown them). A seed that fails (too big for the volume) only
  warns, and the next start tries again while the volume is empty: it
  never stops a boot. Only when asked: other apps' volumes are untouched.
  `volume.seeded` event; `seed: true` in the machine's `volumes`; the
  `mount-hides-files` warning is dropped for a seeded mount and now
  suggests `seed = true`. Tests: `27-files` test_seed_from_an_image,
  `43-volume-owner` test_seed_fills_an_empty_volume_from_the_image,
  `00-config` test_mount_seed_option.
- [x] **flk.toml keys as JSON** (PLAN M6, 2026-11-11). `flk help --all
  --json` has `config_keys`, one `{ key, table, name, type, default,
  flk_only, read, doc }` per key (`read: false` for the fly.toml keys flk
  accepts and ignores). The table is `lib/flk/config_keys.rb`, and the
  parser's unknown-key lists (`AppConfig.known_keys`, was the `KNOWN_KEYS`
  literal) are made from it, so a key can't be read without being listed;
  the lists were compared before and after: identical. `[env]`,
  `[experimental]` and `[deploy]` keys are listed but, as before, not
  checked for typos (fly's own keys there aren't all known to flk). No
  "since" version: flk has one version, 0.1.0. Tests: `00-config`
  test_config_keys_json (shape, the parser's keys are all listed, listed
  defaults are the parser's, the guide's Config section names every key
  flk reads; that found `max_retries` undocumented).

- [x] **`flk releases log [VERSION|FILE] [--failed]`** (lazyflk, 2026-11-11).
  Prints a kept build log: by default the newest build, failed or not (a
  failed first deploy has only `v1-failed-*.log` and no release); `vN`,
  `--failed`, or the file name from `build_log` / a `deploy.failed`
  event's `log`. Exit 1 with `Error:` saying why when there's none
  (pruned, a rollback, before flk kept logs). lazyflk only reads the CLI,
  so it couldn't open the paths. Tests: `05-cli`
  test_failed_build_shows_its_error_and_keeps_a_log, `10-hello`.
- [x] **Image warnings** (PLAN M6, 2026-11-10). `ImageReport.warnings`,
  each `{code, message, fix}`, from the built rootfs: `user-unknown` (a
  USER the image's passwd/group don't resolve), `user-cant-switch` (no
  setpriv, agent or chroot), `no-cmd` (and with the static init: can't
  boot), `no-agent`, `mount-not-dir`, `mount-hides-files`,
  `mount-owner-differs` (a non-root mount point owner other than the USER:
  new volumes copy it). For a registered app, `volume-not-writable`: an
  existing volume's root the USER can't write. Volumes still flagged
  owner_from_image are left to machine start, which owns them if empty and
  else warns there: at deploy the machine is still running, and debugfs
  can't see what it hasn't flushed (the first try missed exactly that).
  `flk build` reports them; a deploy prints them after the build and keeps
  them in the release (`releases --json` "warnings"); `config show` has the
  current release's as `image_warnings`. A failure in the checks only
  prints "couldn't check the image": they run on the real apps' deploys.
  Config warnings (strings, like unknown keys): a `[[mounts]] source` that
  isn't a volume name (`VOLUME_NAME`, shared with `volumes create`), or no
  destination. Checked on the real apps' current releases first: none
  would warn. Tests: `41-build` (each code), `43-volume-owner`
  (volume-not-writable at deploy), `41-build` config show.
- [x] **`flk build`** (PLAN M6, 2026-11-10). Builds the image and rootfs
  as a deploy would (the same code: `Image.make_image`/`make_rootfs`), with
  no registered app and no machines, and reports what flk will do with
  them, read from the rootfs (`ImageReport`): shell or static init, the
  agent, the command and where it came from (flk.toml, image, default),
  workdir, env names, the USER and how init switches to it (`setpriv` /
  `chroot` when the image's own binary knows `--reuid` / `--userspec`,
  `agent` for the static init, `none` for busybox applets: then the app
  runs as root), each mount destination (in the image, owner, entries the
  volume hides), sizes, and `warnings` (filled by the next M6 item).
  The image is `flk.local/APP:build` (label `flk.build`), the rootfs is
  removed after, the log stays in `ROOT/build/APP/build.log`; one build per
  app at a time. `flk images` marks the tag `trial`, `images prune` takes
  it, `apps destroy` removes it, and doctor's orphan check ignores it.
  `image_user` moved to `ImageReport.user`. Tests: `41-build`, and
  `05-cli` test_image_user_switch.

- [x] **flk's images survive a general prune, and `flk images prune`**
  (R1, mud BUGS.flk.md #5, 2026-11-04). A `podman image prune -a` on mud
  removed every image, flk's kept releases included, so each next deploy
  rebuilt from scratch (Enshrouded: 10GB of Steam). Builds are now
  labelled `flk.app=APP`, `flk.release=N`, so
  `podman image prune -a --filter label!=flk.app` spares them (images
  built before, and `[build] image` apps, aren't labelled). `flk images`
  became `flk images list` (still the default, same JSON) plus
  `flk images prune [--dry-run]`: the tags a deploy would prune (never
  one newer than the app's last recorded release: a deploy may be
  building it), destroyed apps' images, and dangling images; base images
  and build caches stay. Tests: `05-cli` test_images_prune (a fake engine
  logs what it would remove), `10-hello` (labels on a real build).
- [x] **A failed build says why, and every build is logged** (R1,
  valheim.flk BUGS.flk.md #2, 2026-11-04). A failed deploy said only
  `podman build failed`; the cause (`ERROR: Steam served build ...`) was
  40 lines up and kept nowhere, so finding it meant a 2GB rebuild. Now
  each step (pull or build, then the rootfs conversion) streams to the
  terminal and to `APP/builds/vN.log`. On failure (`Image::BuildFailed`)
  flk prints "The build said:" (error lines of the failing step only, or
  its last 10 lines), the step shortened (`failed at STEP 2/2 (RUN …):
  exit status 1`) and `Build log: FILE`, just above `build failed;
  machines unchanged`. A failed build's log is renamed
  `vN-failed-TIME.log` (the next try reuses vN); the newest 3 are kept,
  and `vN.log` goes with its release image. `deploy.failed` gets the
  build's first error line in `detail` and a new `log` field;
  `flk releases --json` has `build_log`. The rootfs conversion's own
  errors (`flk: not enough space ...`) come through the same way. Tests:
  `05-cli` (the report's 50-lines-of-noise build; explain_failure on
  multi-stage output; failed-log cap), `10-hello` (a release's log).
- [x] **Rootfs builds work next to their output, not in /tmp** (R1,
  enshrouded.flk BUGS.flk.md #1, 2026-11-04). `flk-build-rootfs` wrote the
  export as a tar and unpacked it, ~2x the image, in `${TMPDIR:-/tmp}`:
  on mud a 15G RAM tmpfs with a quota, so Enshrouded's 10G image failed
  (and without the quota would have taken RAM from the running games).
  Now the work dir is `.flk-rootfs.PID.*` in the app's images dir (the
  same disk as the result); `podman export` streams into tar, with
  `flk-tar-caps` reading the same stream through a fifo (it skips by
  reading on a pipe and drains it, so tee never gets SIGPIPE); free space
  is checked first (2.25x the image's unpacked size + extra_mb + 64MB:
  `not enough space to build the rootfs in DIR`); a later build removes
  work dirs whose PID is gone (builds run outside the global lock, so
  only dead ones). tar's xattr warnings show only when it fails. Tests:
  `08-rootfs` (read-only TMPDIR, the space check before any export,
  leftovers), and a real podman build. Not done: the doctor warning about
  a small `/tmp` tmpfs, since nothing of flk's writes big files there now.
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

- [x] **Releases and boots record their guest kernel** (2026-11-22).
  One kernel serves the host, and `flk setup` replaces it: every
  machine then boots the new one at its next start, and nothing said
  so. `Flk::Kernel.info` gives `{ version, sha256 }` for the kernel
  file: the version is the banner inside the image (what `uname -r`
  says in the guest, `6.18.56+` on mud), else the build config next to
  it; the hash tells two builds of one version apart. It is kept in
  `STATE/kernel-info.json` until the file's size or mtime changes
  (hashing 28MB at every boot would be felt). `VM.launch` stores it in
  the machine (`kernel`, in `status --json`), a deploy or rollback in
  the release (`releases --json`, and a KERNEL column). The boot that
  finds another kernel than the machine's last one says so on the
  terminal and in its event's `detail` (`guest kernel NEW (was OLD)`),
  and every boot event carries `kernel`. `flk setup` prints the change;
  `flk status` names running machines that are still on the old one.
  `doctor --json` and `context --json` have the host's. Machines and
  releases from before have no record, so their first boot after this
  says nothing. Not built: keeping the previous kernel to go back to
  (it needs a way to choose a kernel per app, TODO Guest kernels).
  Tests: `05-cli` test_kernel_info (fast), `16-exec`
  test_the_guest_kernel_is_recorded (a restart on a second kernel).
- [x] **`flk logs --boot`: the log since the latest boot** (enshrouded
  #3, part 2; 2026-11-20). `flk logs` is `tail -n N` of `console.log`,
  so a chatty server's boot scrolls out of reach (enshrouded: 51k lines
  in four days) and its tools couldn't tell whether this boot ever
  printed its ready line. `--boot` prints from the last `--- flk:
  booting` marker on: found by reading backwards 1MB at a time, in
  `console.log.1` when `console.log` has none (the boot began before
  the rotation). All of it by default, so `| head` shows the start and
  `| grep` finds the ready line; `-n N` keeps the last N (through
  `tail`, so no line counting in flk). Following goes on with `tail -c
  +BYTE -F` from where the printing stopped (no gap); with several
  machines, each under tail's own header, then `tail -n 0 -F`. A boot
  older than both files: what's kept, and a note on stderr. Decided:
  `-n` keeps meaning "the last N", with or without `--boot`. Test:
  `tests/cases/05-cli.sh` test_logs_boot (fast: written log files, no
  VM). Tried read-only on mud's five game and service logs (enshrouded's
  boot was in `console.log.1`: 21,529 lines from the marker, 0.16s).
- [x] **`[flk] log_max_mb`: an app's own console.log limit** (enshrouded
  #3, its last part; 2026-11-21). `FLK_LOG_MAX_MB` is one limit for the
  whole host, and it comes from the environment of whichever flk starts
  the machine. A chatty server passes 2 x 10MB between restarts, and
  then `flk logs --boot` and a `log` check have lost the boot's start.
  `log_max_mb = N` (a whole number, at least 1) is kept in the machine's
  config at deploy, and `VM.launch` gives `flk-logpipe` that limit when
  the machine boots (`VM.log_max_bytes`); unset, the host's limit as
  before. No upper bound: the cost is disk, up to twice the limit per
  machine. To keep a big log from costing memory, `flk check`'s `log`
  check no longer reads the whole boot at once: it reads 1MB at a time
  (`boot_log_match?`), tries whole lines only until the end, and starts
  each piece with the last 64KB of lines of the one before, so `$`
  never matches where a read stopped and a match across two reads is
  found. Found on the way: console bytes were matched as binary, so a
  check or `console --wait-log` whose regex has a character outside
  ASCII raised (`Encoding::CompatibilityError`) on a log with any such
  byte; they are now read as UTF-8 with bad bytes replaced
  (`console_text`). The `logs --boot` note about lost lines names the
  key. Tests: `00-config` test_log_max_mb, `05-cli`
  test_log_check_reads_a_big_boot (fast), and `16-exec`
  test_console_log_rotates_at_the_apps_limit (a machine with
  `log_max_mb = 1` writes 1.2MB to its console and rotates).
- [x] **`flk ssh mount PATH DIR`: a running machine's directory on the
  host** (Dayne's idea, 2026-11-17). sshfs, with nothing listening in
  the guest: sshfs runs `libexec/flk-sftp` in place of ssh (by name, its
  directory put on sshfs's PATH, because sshfs 3.7 can't take a command
  path with a space), which is `flk ssh sftp-stdio`: the image's
  `sftp-server` started through flk-agent as `--user`, in that user's
  home (sshfs takes the home's owner for the remote user, so `idmap=user`
  shows the guest user's files as the host user's). The mount's source,
  `USER@MACHINE.APP.flk`, carries everything the stand-in needs, so flk
  keeps no list: `flk ssh mounts` reads the kernel's mount table, and
  sshfs's `reconnect` brings a mount back after a restart or deploy.
  Before mounting, flk checks sshfs and fuse on the host, and in the
  guest the server, `sh`, the directory and that the user can enter it,
  each with its own message (the missing-server one names the packages).
  `--read-only` is both sshfs's `ro` and the server's `-R`. `flk ssh
  unmount DIR|--all [--force]`; destroying a machine or app detaches its
  mounts; `flk status` lists them (`ssh_mounts` in `--json`). Directory
  cache 5s (sshfs's 20s kept listing a stopped machine's files). Known
  limits, in the command's help: an absolute symlink to outside the
  mounted directory names a host file; slow for builds; gone after a
  host reboot. Tests: `46-ssh-mount` (8, skipped without sshfs); by hand:
  an image without `sh`, flk under a path with a space and a comma.
  Examples for others (2026-11-17, after it worked on another person's
  host): `examples/devbox` (Ubuntu 26.04, a user, its home on a seeded
  volume; tried as a `flkt-*` app: mount, write, deploy, still there),
  the Dockerfile lines for Ubuntu/Debian, Alpine and Fedora (each
  installed in a container to check the server's path) in `flk help
  operate`, `dockerfile`, `troubleshoot` and the command's own help.
- [x] **A non-root USER runs as itself on busybox images** (TODO
  Machines, 2026-11-10, before M6's warnings). Alpine's busybox has no
  `setpriv --reuid` and no `chroot --userspec`, so init ran the app as root
  with one line in the boot log. flk-agent 4 has `run-as USER CMD...`
  (names from the image's passwd and group, groups cleared, setgid then
  setuid, then exec; an unknown user runs as root with init's warning, so
  a boot never breaks on it), and init.sh tries it after util-linux
  setpriv and before chroot, when the agent says it's version 4 or later
  (an old prebuilt agent ships when Go is gone). `flk build` reports
  `switch: "agent"`. The real apps' images were checked: Ubuntu-based with
  setpriv, or root; none changes. Tests: `43-volume-owner` (the app is up
  as 1100), `41-build`, `05-cli` test_image_user_switch.

- [x] **A missing root disk is made again at start** (R1, mud
  BUGS.flk.md #4, 2026-11-04). mud's restic backup skips machines'
  `rootfs.ext4` (copies of `images/vN.ext4`); after a restore,
  `flk resume` failed (firecracker couldn't open the drive) and the
  runbook had a manual cp per machine. `VM.start` now copies it from the
  release image when it's missing and says so; if the image is gone too,
  the error says to redeploy. Test: `10-hello`
  test_start_recreates_a_missing_root_disk.
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
