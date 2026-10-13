# System notes (for a future host-improvement session)

This file covers the host flk runs on (disks, backups, kernel settings,
the two game servers), not flk's code. flk's own roadmap is `PLAN.md`.
A session that works on the system rather than the tool starts here.
Written 2026-10-13.

## Ground rule

Dayne, 2026-10-13: `minecraft-flk` and `vintagestory-flk` keep running.
Anything that stops, restarts or redeploys them waits for a maintenance
window that Dayne picks. Players are on both.

## Current host

- **Disks:** one 2TB NVMe (WD SN770), VG `ubuntu-vg`, with about 1TB
  unallocated after the backups LV. Everything is ext4, which has no
  reflinks:

  | Mount | Size | Free | Holds |
  |---|---|---|---|
  | `/` | 98G | 75G | flk's state dir `~/.local/share/flk` |
  | `/data/minecraft` | 98G | 32G | `flk/world.ext4`, 21G |
  | `/data/vintagestory` | 147G | 62G | `vsdata` |
  | `/data/flk-backups` | 393G | 228G | backups: 146G used, 123G of it Minecraft |

- **Host config:** `~/.config/flk/host.toml` has `backup_dir`,
  `backup_keep = 7`, `address` and `bind = 10.47.11.3`. The NIC carries
  10.47.11.116 (DHCP) and 10.47.11.3 (netplan). Game ports answer only
  on .3.
- **Memory:** 30G RAM. THP is `madvise`. There is no hugetlb pool
  (`HugePages_Total` is 0).
- **Backups:** nightly from each game's cron (`mc-backup` at 02:00, VS's
  own). They copy without flooding the page cache since flk 553b1a3.
- **Services:** `flk-net` and `flk-machines` are enabled. The boot
  service, the exit hook and the cron jobs all run
  `/home/dayne/flk/bin/flk` from master.

## Risks

1. **One disk holds everything.** The worlds, the backups and flk's
   state are all on the same NVMe, so a dead drive loses all of it. Both
   game TODOs list "off-host copy" as open.
2. **Backup space.** Every backup is a full copy (ext4). Seven nights of
   both games is about 260G of 393G, and it grows with the worlds.
3. **Restore room.** An in-place restore keeps the replaced image next to
   the live one. That's 21G for Minecraft on `/data/minecraft`, which has
   32G free.

## Decisions for Dayne

1. **Off-host copy target:** a NAS, a USB disk, or another host over
   ssh? Once flk's off-host copy lands (PLAN.md, M1), it only needs the
   target in `host.toml`.
2. **XFS LV for volumes and backups:** XFS has reflinks, so backups would
   take seconds and the pause mode milliseconds.
   - Creating the LV needs root but doesn't stop anything.
   - Moving the game volumes onto it waits for the window.
   - Alternative: LVM thin snapshots (minecraft's TODO). They need root
     on every snapshot.
3. **Huge pages for Minecraft (minecraft BUGS #8):**
   - The cost is about 1.8G more in practice (the VM already holds
     ~9.2G), but 11G stays reserved even while the VM is stopped.
   - Commands:

     ```
     sudo sysctl -w vm.nr_hugepages=5632
     echo 'vm.nr_hugepages = 5632' | sudo tee /etc/sysctl.d/60-flk-hugepages.conf
     ```

     Then check `HugePages_Total` in `/proc/meminfo`.
   - The deploy that switches it on is a window item.

## Maintenance window (needs the game servers stopped or redeployed)

- **Huge pages for Minecraft:** add `huge_pages = "2M"` to `[[vm]]` and
  `flk deploy` (after the reservation above). Then mark BUGS #8 resolved.
- **XFS:** move `world` and `vsdata` onto the XFS LV, if decision 2 is yes.
- **Back up before deploy:** turn on `[flk.backup] before_deploy` for
  each game, once flk has it (PLAN.md M1).
- **Vintage Story's root-owned volume root:** fix `/` in `vsdata.ext4`
  (from `mkfs.ext4 -d`) with the VM stopped. Use
  `debugfs -w -R "sif / uid 1000"` plus gid, then fsck, or
  `flk volumes chown` once it exists (PLAN.md M2).
- **Guest changes:** redeploy both games to pick up whatever has landed
  by then, such as a vsock agent (PLAN.md M3).
- **Restore test:** test a real in-place restore once. Before then, a
  restore into a new volume (PLAN.md M1) tests backups without a stop.

## Other hosts (testing flk's portability)

flk's firewall and distro code has only run on this Ubuntu host, with
Docker's firewall rules. The full test steps are in `TODO.md` under
"Setup and host checks". Each needs a host (VMs would do):
- Fedora: firewalld and dnf.
- Arch: pacman.
- Ubuntu with `ufw enable`.

## Things to keep an eye on

- `/data/flk-backups` usage: `flk disk`, `df -h /data/flk-backups`.
- After a week of the cache-friendly backups, decide whether `swappiness`
  10 still matters (minecraft TODO).
- Old snapshots and images left on the game disks (VS `orig/` 59G,
  `dotnet*`; see each game's TODO).
