# Looking after a flk host while apps run

What's safe to do on the host, and what stops machines.

**flk's services.** Three systemd units, from
`sudo {{SRC}}/setup-host.sh --install-service`:
- `flk-net.service`: the bridge, the tap pool and the nft rules. Its stop
  removes them (`setup-host.sh --down`) from under running machines:
  `flk stop-all` before restarting it, `flk resume` after.
- `flk-tmux.service`: flk's tmux server; every machine runs in it.
  Stopping it stops every machine gracefully; restarting it (needrestart
  does, after some apt upgrades) stops them and starts them again, a short
  outage. Units installed before that: doctor says so, and
  `flk resume` brings the machines back.
- `flk-machines.service`: `flk resume` at boot, `flk stop-all` at
  shutdown. Restarting it does the same: stop all, start all.

`flk doctor` checks they're installed and current; after updating flk,
re-run `--install-service` when it says so (it doesn't stop machines).

**Upgrades.** `apt upgrade` is safe; expect a short stop of every machine
if needrestart restarts `flk-tmux.service`. To avoid even that, tell
needrestart to leave flk's units alone: a file in `/etc/needrestart/conf.d/`
with `$nrconf{override_rc}{qr(^flk-)} = 0;` (check with
`sudo needrestart -b -r l`), and restart them in a quiet moment. A host
kernel update needs no flk step: flk's firecracker and guest kernel are
its own downloads (`flk setup`), not the distro's.

**Reboots.** Machines stop gracefully at shutdown and come back at boot
(the services above). `flk stop-all` / `flk resume` do the same by hand.

**Things that stop machines.** `flk stop-all`, `flk stop`, stopping or
restarting the services above, `tmux -L flk kill-server`, killing
firecracker processes, a reboot without the services, and a `stop`-mode
backup (for the copy only).

**Disk space.**
- `flk disk` shows what flk uses, per app: release images, machine disks,
  volumes, logs, backups.
- A deploy needs about twice the image's size free next to flk's release
  images (not in /tmp).
- `flk images prune` frees podman's store of what flk doesn't keep.
  Don't use `podman image prune -a`: it removes flk's kept images (no
  rollback until the next deploy) and every base image (the next build
  downloads them again). To prune the rest of the store:
  `podman image prune -a --filter label!=flk.app`.
- Backups: `backup_dir`, `backup_keep` and `backup_copy_to` in
  `~/.config/flk/host.toml` (`flk config set`); `flk apps prune --backups`
  removes those of destroyed apps.

**Backing up the host.** flk's state dir (`flk context` shows it) and any
external volume files. Machines' `rootfs.ext4` can be skipped: they're
copies of the release images, and start makes a missing one again.

**Where to look.** `flk events` (what happened, `--json`), `flk logs`,
`{{ROOT}}/hooks.log` (the exit hook), `journalctl -u flk-tmux -u
flk-machines -u flk-net`.
