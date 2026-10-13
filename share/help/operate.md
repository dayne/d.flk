# Running apps day to day

**See what's there.** `flk context --all` lists every app, machine, IP and
port on the host, and what needs attention. In an app directory,
`flk context` and `flk status` cover that app; elsewhere add `-a APP`.

**Ship a change.** Edit code or `flk.toml`, then `flk deploy` from the app
directory. Each deploy is a new release (`flk releases`); machines are
updated one at a time. flk warns about flk.toml keys it doesn't know
(typos like `kill_timout`).

**Health checks and rollback.** With checks in flk.toml, a deploy waits
for each machine to pass them before updating the next:

    [checks.ready]
      type = "log"               # flk's own: a console line (game servers)
      match = "Done \\("
      grace_period = "3m"        # how long it may take (default 60s)
    [checks.port]
      type = "tcp"               # or "http" with path = "/health"
      port = 25565

A machine that fails goes back to its previous release, the new release is
marked failed (`flk releases` says why), and the deploy stops; `--no-rollback`
leaves it there to debug. fly's `[[services.tcp_checks]]`,
`[[services.http_checks]]` and `[[http_service.checks]]` work too.
`flk releases rollback [vN]` goes back to an older release's image and
config (default: the one before; or, when `--no-rollback` left machines on
a failed release, the last good one), as a new release with the same checks.
The last two images are kept; `[flk] keep_releases = N` keeps more.
Deploys and rollbacks boot the machines they update, stopped ones too.

By default volumes aren't rolled back, by a failed deploy or by `releases
rollback`: only the image and config are. That matters when data on the
volume must match the image (game mods or server jars kept on the
volume): an automatic rollback would boot the old image on the new data.
For such upgrades take `flk volumes backup` first and deploy with
`--no-rollback`; to undo, stop the machine, `flk volumes restore NAME`,
then `flk releases rollback`. Or let flk do it: with `[flk.backup]
before_deploy = true` each deploy backs up the volumes while the machine
is stopped for the update, a failed health check puts them back with the
old release, and `flk releases rollback --with-volumes [vN]` restores
them later (after backing up what's there now).

**Logs.** `flk logs` shows the last 50 lines of every machine (`-n 500`
for more, `-i ID` for one, `-f` to follow). Logs rotate at 10MB
(`console.log.1` keeps the previous part) and survive restarts.

**Talk to the app.** `flk console ID` attaches to its serial console: what
you type goes to the app's stdin (Minecraft: `say hi`, `stop`). Leave with
Ctrl-b d (Ctrl-b Ctrl-b d inside tmux). Ctrl-C there doesn't stop the app.
For one command without attaching: `flk console ID --send "say hi"`; add
`--wait-log "REGEX"` to print the app's answer (scripts and agents too).

**Stop and start.** `flk machine stop ID` stops a machine and keeps it
stopped, across reboots too. `flk machine start ID` brings it back.

**Crashes.** When an app crashes or exits non-zero, flk restarts it (1s, 2s,
4s... apart, 10 times in a row at most; `[[restart]]` in flk.toml changes
that, `policy = "never"` turns it off). The log shows each restart. If it
gives up, `flk context` says so: read `flk logs -i ID`, fix, then
`flk machine start ID`. An app that exits cleanly (status 0) stays
stopped but counts as "should be running": `flk resume` starts it again.

**Reboots.** With `flk-machines.service` installed (`flk doctor` checks),
machines stop gracefully at shutdown and come back at boot. Without it:
`sudo {{SRC}}/setup-host.sh`, then `flk resume`.

**Secrets and config.** `flk secrets set K=V` restarts running machines;
`--stage` waits for the next deploy or restart. `flk config show` prints the
config flk derived, `flk machine status ID` what a machine runs with.

**More machines.** `flk scale count N`. Each machine needs its own volume
per `[[mounts]]` entry: create them first. Host ports go to the first
running machine; the next takes over when it stops.

**LAN addresses.** Forwarded ports answer on every address the host has,
so a second address (say 10.47.11.3 next to the DHCP one, added with
netplan) works with no flk change. In `~/.config/flk/host.toml`:

    address = "10.47.11.3"   # what flk shows people (hints, ports, context)
    bind    = "10.47.11.3"   # forward ports only there, for every app

or per app, `[flk] bind = "10.47.11.3"` in flk.toml (a list works; `"all"`
undoes a host-wide bind), then `flk deploy`. Host settings apply at the
next `flk ports sync`. Two apps can then use the same port on different
addresses. `bind` needs the port helper from a current
`sudo {{SRC}}/setup-host.sh`; until then flk keeps forwarding on every
address and `flk doctor` says so. doctor also warns about an address
that isn't on this host (expected for a floating one another host holds).

**Big memory (game servers).** `[[vm]] huge_pages = "2M"` backs the
guest's memory with 2M pages from a pool you reserve once (root):
`sudo sysctl -w vm.nr_hugepages=N` plus the same line in `/etc/sysctl.d/`,
N = memory MB / 2 for every such machine. Fewer TLB misses for a big Java
heap, and the memory is never swapped; but it's held even when the VM is
stopped. flk refuses to start a machine without enough free pages and
prints the commands; `flk doctor` shows the pool. Without a pool, the
host-wide alternative is THP `always` (`/sys/kernel/mm/transparent_hugepage/enabled`).

**Disk.** Everything is under `{{ROOT}}`: two release images per app,
volumes (unless created with `--path`), logs. `flk apps prune` removes
images of destroyed apps. Volumes on other disks (`--path`):
put the disk in `/etc/fstab` (without `nofail`) and reboots mount it before
machines start, and stop machines before unmounting it. `flk doctor` warns
if a disk isn't covered, e.g. a `nofail` or network mount: then re-run
`sudo {{SRC}}/setup-host.sh --install-service` once.

**Backups.** Set where they go once, in `~/.config/flk/host.toml`:

    backup_dir  = "/data/flk-backups"   # ideally another disk than the volumes
    backup_keep = 7                     # per volume

Then `flk volumes backup` copies all of the app's volumes there (sparse:
only used space), checks each copy with e2fsck, and deletes the oldest past
`keep`. By default the machine is stopped for the copy and started again
(seconds to minutes of downtime, by size); `[flk.backup]` in flk.toml can
copy while it runs instead, with hooks that make the app save and pause
writing (`flk help --all`, Config). `flk volumes backups` lists them;
`flk volumes restore NAME [BACKUP]` (machine stopped) puts one back and
keeps the replaced image beside it. To test a backup without stopping
anything: `flk volumes verify NAME` (e2fsck read-only, plus the
`[flk.backup] verify` hook if set), or `flk volumes restore NAME --as
NEWNAME`, which copies it into a new volume and leaves everything else as
it is.

**Copies off this disk.** A backup on the same disk as the volume doesn't
survive that disk. Add `backup_copy_to = "/mnt/usb/flk"` (another disk) or
`"user@nas:/srv/flk"` (rsync over ssh, with a key: no password prompts) to
`~/.config/flk/host.toml`, and every `flk volumes backup` then copies the
new backup there too, keeping `backup_copy_keep` (default `backup_keep`) per
volume. `flk volumes copy` sends one by hand (it skips what's already
there), `flk volumes backups` shows where each backup was copied, and
`flk doctor` warns when a volume's newest copy is older than
`backup_copy_warn_days` (8). `flk volumes extend NAME --size GB`
grows a volume (machine stopped).

On a schedule, with a systemd user timer (no root;
`loginctl enable-linger $USER` once so it runs while you're logged out):

    # ~/.config/systemd/user/flk-backup-APP.service
    [Service]
    Type=oneshot
    ExecStart={{SRC}}/bin/flk -a APP volumes backup

    # ~/.config/systemd/user/flk-backup-APP.timer
    [Timer]
    OnCalendar=*-*-* 04:00
    Persistent=true
    [Install]
    WantedBy=timers.target

    systemctl --user daemon-reload && systemctl --user enable --now flk-backup-APP.timer

Machines deployed before flk had `live` backups write their cache out
lazily (up to 35s): redeploy them, or use `settle = 35` until then.

**Updating flk.** `git -C {{SRC}} pull`, then `flk setup` for a newer
firecracker or kernel. Running machines pick changes up on their next
deploy or restart.

When something's wrong: flk help troubleshoot
