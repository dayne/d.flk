# Plan (2026-10-13)

This is the roadmap for flk, the tool: its commands and capabilities.
Host work (disks, backup targets, kernel settings, the game servers'
maintenance) is in `SYSTEM-NOTES.md`, for a separate session. The details
of each item are in `TODO.md`. This file sets the order.

Sources: `TODO.md`, the flk requests in `~/minecraft.flk` and
`~/vintagestory.flk` (TODO.md, BUGS.flk.md), and lazyflk's `TODO.md` (github.com/dayne/d.lazyflk).

## Rules while building

- Real apps run on main's `bin/flk`: the boot service, the exit hook
  and the games' cron backups all use it. New behaviour in those paths
  must be opt-in, or a no-op for an app that doesn't ask for it.
- Changes to the guest (`/flk/init`, agents) reach a machine only when it
  boots again. Keep flk working with guests that don't have them.
- Tests use `flkt-*` apps only. Never start, stop, deploy or back up
  `minecraft-flk` or `vintagestory-flk`.
- CLI and JSON are lazyflk's API, so changes are additive. Record what
  lazyflk needs in `TODO.md`.

## Where flk stands

- Done:
  - deploys with health checks, rollback and releases
  - volume backups (modes, hooks, fsck, page-cache-friendly), restore and
    extend
  - LAN addresses
  - huge pages
  - agent-friendly help and context
  - lazyflk gaps G1–G11
- Gaps that real use has shown:
  - A restore only works in place and needs the machine stopped, so a
    backup can't be tested without downtime.
  - flk can't copy backups anywhere but `backup_dir`.
  - Nothing warns that a backup won't fit before it starts.
  - Rolling back a release restores the image but not the volume.
  - Getting at files in a volume needs root and hand-made scripts (both
    game repos carry one).
  - There's no event history, so lazyflk polls. There's no exec, so
    scripting goes through the console.

## Milestones

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

### M4: Networking between apps

- **`APP.internal` DNS**: dnsmasq on `flkbr0`, fed from machine records.
- **Ports on 127.0.0.1**: an opt-in `route_localnet` mode with a doctor
  warning, and UDP for `flk proxy`.

### M5: More than one host (design first)

These items depend on M1's copies and M3's events:
- managed extra addresses
- keepalived hooks (`flk host activate|deactivate|check`)
- `flk volumes sync --to HOST`
- fencing so an app never runs on two hosts

Start with a written design.

### Alongside (small, any time)

- A friendlier tmux prefix for `flk console` inside tmux, and tmux
  server groups.
- Machine snapshots (Firecracker snapshot/restore), after M3.
