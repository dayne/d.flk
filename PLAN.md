# Plan (2026-10-15)

This is the roadmap for flk, the tool: its commands and capabilities.
Host work (disks, backup targets, kernel settings, the game servers'
maintenance, other-distro test hosts) is in `~/mud`
(`docs/flk-system-notes.md`), for a separate session. The details of each
item are in `TODO.md`; this file sets the order. Finished milestones
(M1–M4, first install) and the decisions behind them are in
`docs/history.md`.

Sources: `TODO.md`, the flk requests in `~/minecraft.flk` and
`~/vintagestory.flk` (TODO.md, BUGS.flk.md), and lazyflk's `TODO.md`
(github.com/dayne/d.lazyflk).

## Rules while building

- Real apps run on main's `bin/flk`: the boot service, the exit hook
  and the games' cron backups all use it. New behaviour in those paths
  must be opt-in, or a no-op for an app that doesn't ask for it.
- Changes to the guest (`/flk/init`, agents) reach a machine only when it
  boots again. Keep flk working with guests that don't have them.
- Tests use `flkt-*` apps only. Never start, stop, deploy or back up any
  other app (`minecraft-flk`, `vintagestory-flk`, `mqtt-flk`,
  `opencode-sandbox`...).
- CLI and JSON are lazyflk's API, so changes are additive. Record what
  lazyflk needs in `TODO.md` ("For lazyflk").

## Where flk stands

One host runs fly.io-style apps end to end: deploys with health checks,
releases and rollback; volumes with verified backups, copies off the disk
and rollback with a release; files in volumes without root; events, exec
and `APP.internal` names; a first install that leads the way. lazyflk's
gaps G1–G16 are closed.

What's missing:
- More than one host: no failover, no volume sync (M5).
- Distro coverage: ufw and firewalld have never run on a real host (host
  work, `~/mud`); Fedora has no install test; the install tests run as
  root.
- Instant snapshots: backups are full copies on ext4.

## Next

### Small, first

- A Fedora install test, and the install steps as a non-root user
  (TODO.md, Setup).

### M5: More than one host (design first)

These items build on M1's copies and M3's events:
- managed extra addresses
- keepalived hooks (`flk host activate|deactivate|check`)
- `flk volumes sync --to HOST`
- fencing so an app never runs on two hosts

Start with a written design.

### Alongside (any time)

- flk's tmux server keeps its groups (TODO.md, Machines).
- Machine snapshots (Firecracker snapshot/restore): nothing blocks it.
- Volume snapshots: need volumes on a reflink filesystem or LVM thin (a
  host decision first, `~/mud`).
