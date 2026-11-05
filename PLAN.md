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
  work, `~/mud`). The install tests cover Ubuntu, Arch and Fedora up to
  setup-host.sh, as a normal user.
- Instant snapshots: backups are full copies on ext4.

## Next

Order (decided 2026-11-04): R1, then M6, then M5 once Tailscale is
settled.

### R1: Reliability (the apps' reports): done 2026-11-05

The real apps filed verified flk bugs in their own `BUGS.flk.md`; the
index and the decided behaviour for each are in TODO.md ("Reported by
apps", "Reliability"). In order of harm:
- mud #6: a restart of flk-tmux.service (needrestart) leaves every VM
  down. Resume after a restart, never at boot.
- enshrouded #1: rootfs builds in a RAM tmpfs. Work next to the output,
  stream the export, check free space.
- valheim #2: a failed build hides why. Error lines up front, a build log
  per release (plus the last 3 failures), the path in the event.
- valheim #4, #5, #6: volume owner from the image USER (repairs: the
  existing `flk files chown`); before_deploy verify can't trap a broken
  app (`FLK_BACKUP_REASON`, `deploy --no-backup`, a warning when the
  release never got healthy); no TCP wait on UDP-only apps.
- enshrouded #2, mud #4, mud #5: copy before_deploy backups after the
  roll; recreate a missing rootfs on start; label flk's images, plus
  `flk images prune`.
- Docs: help topics `dockerfile`, `host`, `bugs`.

Each fix comes with its report's test and updates the report's status.
Done: merged to main at 7f0317f (2026-11-05); the flkforge session was
told and the app repos' status lines name main.
New commands and JSON (`images prune`, `build_log`, the
event's `log`) go to lazyflk as a note.

### M5: More than one host (design first)

These items build on M1's copies and M3's events:
- managed extra addresses
- keepalived hooks (`flk host activate|deactivate|check`)
- `flk volumes sync --to HOST`
- fencing so an app never runs on two hosts

A draft design is in `docs/m5-design.md` (2026-10-16): one holder per app
with an epoch, checked on every start path, and the order of work (P0
peers, P1 planned moves, P2 addresses, P3 takeover). It waits on
Tailscale and the other larger pieces, which decide its open questions
(transport, service address, witness). Settle those before building
past P0.

### M6: Making apps (for flkforge)

flkforge (`~/d.flkforge`) writes new apps from snippets. What it needs
from flk is in TODO.md ("For flkforge"). Nothing here waits on M5, so it
comes after R1. In order:
- `flk build`: build and inspect an image without deploying. It's the
  base for the rest and useful on its own to anyone writing a Dockerfile.
- Image warnings at build/deploy (no user switch, no CMD, a mount over
  image files, volume ownership).
- Checks as one design: `exec` (through the agent), `udp`/`a2s`
  (valheim #1), and a `[deploy] preflight` host hook (valheim #3).
- `[[mounts]] seed = true`: fill a new volume from the image.
- flk.toml keys in `help --all --json` (the exact guest env list is done: R1 docs).

flkforge's own order (2026-11-05): `flk build`, then `seed = true` (its
core/home-volume seeds with a script today), then `exec` checks, then
the keys in `--json` (`flkforge explain KEY` parses the help text today).
Dayne decides between the two orders when M6 starts.

All of it is additive and opt-in, so real apps are unaffected. Tell
flkforge about each one with the commit and its JSON, as with lazyflk.

### Alongside (any time)

- A non-root USER silently runs as root on busybox images (TODO.md,
  Machines): small, and do it before M6's image warnings.
- flk's tmux server keeps its groups (TODO.md, Machines).
- Machine snapshots (Firecracker snapshot/restore): nothing blocks it.
- Volume snapshots: need volumes on a reflink filesystem or LVM thin (a
  host decision first, `~/mud`).
