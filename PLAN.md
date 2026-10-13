# Plan (2026-10-13)

This plan is based on `TODO.md`, the flk items in `~/minecraft.flk` and
`~/vintagestory.flk` (TODO.md, BUGS.flk.md) and `lazyflk/TODO.md`.
`TODO.md` still holds the details of each item. This file sets the order.

## Ground rule: leave the game servers running

Dayne, 2026-10-13: `minecraft-flk` and `vintagestory-flk` keep running.
Any change that would mean stopping, restarting or redeploying them waits
for a later maintenance window. Those parts are marked **(window)** below
and are collected at the end of this file.

What this means while building:
- New flk code is fine. It must not change what the running servers do
  until someone opts in. Their cron backups and the boot service run
  `/home/dayne/flk/bin/flk` from master, so new behaviour in `backup` or
  the exit hook needs a setting to switch it on, or must be a no-op for
  them.
- Changes to the guest (`/flk/init`, a vsock agent) reach a machine only
  when it boots again. Build and test them on `flkt-*` apps, and let the
  game servers pick them up in the window.
- Test with `flkt-*` apps only, as before.

## Where things stand

- Two real game servers run on flk. lazyflk v1 is done.
- Deploys are safe: health checks, rollback, releases.
- Nightly backups run without flooding the page cache.
- No bug reports are open. The only open request is minecraft #8, huge
  pages, which needs a decision from Dayne (see the end of this file).
- The biggest risk now is the data:
  - The worlds, the backups and flk's state are all on the same 2TB NVMe.
    Both game sessions list "off-host copy" as open.
  - Every backup is a full copy, because all four filesystems are ext4,
    which has no reflinks. `/data/flk-backups` already holds 146G of
    393G, and Minecraft alone holds 123G.
  - A restore works only in place. The machine has to stop, and the
    replaced image (21G) has to fit next to the world. `/data/minecraft`
    has 32G free.
  - Rolling back a release restores the image but not the volume, while
    both games keep their jars and mods on the volume.
- Both game repos carry hand-made tools to get at files on a volume
  (`mc-edit`, `vs-edit`, debugfs, root-owned files). That points to a
  gap in flk.

## Milestones

### M1: Data safety (next)

The goal is backups that survive a dead disk, restores that can be tested
without downtime, and space use that stays predictable.

1. **`flk volumes restore --as NAME`**: restore a backup into a new
   volume (or a path) next to the live one, with no stop and nothing
   replaced. That makes restore tests routine. Pair it with
   `flk volumes backup --verify ID`, which runs e2fsck and an optional
   `[flk.backup] verify` hook against a copy.
2. **Off-host copies**: `[host] backup_copy_to = "user@nas:/path" |
   "/mnt/disk"`.
   - After each backup, flk sends the newest one with rsync
     (`--sparse`, with resume), keeping its own number of copies there
     (`copy_keep`).
   - `flk volumes backups` shows where each backup is.
   - Doctor warns when the last copy is older than N days.
3. **Space checks**:
   - Before a backup, estimate whether `keep` × the size used will fit in
     `backup_dir`, and refuse early instead of filling the disk.
   - Doctor warns when it's tight.
   - `flk disk` shows the backups per volume.
4. **Opt-in volume rollback**: `[flk.backup] before_deploy = true` takes a
   backup before the roll. If a health check fails, flk restores that
   backup (machine stopped) before booting the old release. Releases
   record that backup ID, so `releases rollback --with-volumes` can do the
   same later.
   - This is slow on ext4 (a full copy), so it stays opt-in and reports
     the time.
   - It becomes cheap after M1.5.
5. **Instant snapshots (needs a host change, Dayne)**: put volumes and
   backups on a filesystem with reflinks (an XFS LV in `ubuntu-vg`, which
   has about 1TB free). flk already uses reflinks when it can.
   - That makes backups take seconds, pause mode take milliseconds, and
     items 4 and 1 nearly free.
   - flk's part is a doctor hint, `flk volumes move VOL --to DIR` (a
     sparse copy with the machine stopped), and docs.
   - LVM thin snapshots, which minecraft's TODO mentions, are the
     alternative. They need root on every snapshot, so XFS comes first.

Doable now, with no stop: items 1–3, item 4's code, and item 5's flk
part plus creating the LV. **(window)**: enabling `before_deploy` for a
game (it applies on its next deploy) and moving a game volume to XFS.

Done when: both games have a weekly copy on another disk or host, a
restore test run with `--as` (a backup restores while the server keeps
running), and a doctor check for each.

### M2: Volume files without sudo

The goal is that `mc-edit`, `vs-edit` and debugfs one-liners are no longer
needed.

- `flk volumes ls|cat|cp|rm|mkdir|chown VOL PATH`, built on `debugfs -w`
  (no mount, no root).
  - flk refuses while a machine has the volume attached, unless `ls` and
    `cat` are run against a backup.
  - `cp` into a volume sets uid/gid (`--owner`, defaulting to the parent
    directory's owner). That fixes the VS root-owned `/` gotcha.
  - Every write ends with an e2fsck of the image.
- Tests on a scratch volume. Then offer the two game sessions the commands
  as a replacement for their scripts. Reading their backups works now.
  Writing to their live volumes needs the server stopped **(window)**,
  and that includes the VS `chown /` fix.

### M3: Talk to running machines

- **G7 events** (the last lazyflk gap): `flk events [--json] [--follow]`.
  - An append-only `events.jsonl` in the state dir (rotated), written by
    lifecycle commands and the tmux exit hook.
  - Covers start, stop, exit, restart, give-up, deploy, rollback, check
    pass/fail, backup and port changes.
  - lazyflk can then stop polling, and agents get a history ("why did it
    restart at 03:12?").
- **Exec over vsock**: a small static agent in the guest, started by
  `/flk/init`.
  - `flk ssh console` (a real shell) and `flk exec ID -- CMD` (exit code,
    stdout and stderr kept apart).
  - That replaces `console --send`/RCON for scripting, and allows an
    in-guest `sync`/fsfreeze before live backups (better consistency than
    the 1s writeback).
- **Static init** (same toolchain as the agent): distroless/scratch
  images boot.
- The game servers get the agent on their next deploy **(window)**. Until
  then, flk has to keep working with guests that don't have it
  (`console --send` and RCON).

### M4: Networking between apps

- **`APP.internal` DNS**: dnsmasq on `flkbr0`, fed from machine records,
  so machines resolve each other by app name.
- **Ports on 127.0.0.1**: the optional `route_localnet` mode, off by
  default with a doctor warning, plus UDP for `flk proxy`.

### M5: More than one host (later; design first)

These items depend on M1's off-host copies and M3's events:
- managed extra addresses
- keepalived hooks (`flk host activate|deactivate|check`)
- `flk volumes sync --to HOST`
- fencing so an app never runs on two hosts

Start with a written design in `share/` before any code.

### Alongside (small, any time)

- Firewall and distro passes: Fedora (firewalld), Arch, Ubuntu with ufw.
  This needs those hosts, so Dayne picks when (VMs on this host would do).
- A friendlier tmux prefix for `flk console` inside tmux, and tmux
  server groups.
- Machine snapshots (Firecracker snapshot/restore): after M3, because
  vsock state complicates restore.

## Decisions for Dayne

1. **Off-host target for M1.2**: which machine or disk (NAS, USB disk,
   another host over ssh)?
2. **XFS LV for volumes (M1.5)**: OK to create one now (root, in
   `ubuntu-vg`; no stop needed)? Moving the game volumes onto it waits
   for the window.
3. **Order**: M1 then M2 is the suggestion, because the risk to data
   comes first and both games want M2. M3 could go first if lazyflk's
   polling or exec matter more to you.

## Maintenance window (later, Dayne picks the time)

These need the game servers stopped or redeployed:
- Huge pages for Minecraft (BUGS #8):
  - Reserve the pages: `vm.nr_hugepages=5632`. That's about 1.8G more
    in practice, but 11G stays held even while the VM is stopped.
  - Then add `huge_pages = "2M"` and `flk deploy`.
- Move `world` and `vsdata` to the XFS LV (`flk volumes move`, M1.5).
- Turn on `[flk.backup] before_deploy` for each game (M1.4).
- Vintage Story: the volume root is owned by root. Fix it with
  `flk volumes chown` (M2) or debugfs, with the VM stopped.
- Redeploy both games to pick up the guest changes that have landed by
  then (the M3 agent).
