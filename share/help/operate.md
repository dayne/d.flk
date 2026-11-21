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

**Health while running.** `started` only means the VM is alive. To know
whether the app still answers, give its checks an `interval`:

    [checks.port]
      type = "tcp"
      port = 25565
      interval = "5m"            # also try it every 5 minutes while it runs

`flk check` runs an app's checks now (`--all`: every app) and keeps each
result per machine; `flk status` shows them with how long each has been
passing or failing (`checks` in `status --json`), and `flk context` lists
a failing one under Next steps. With the boot units installed
(`sudo {{SRC}}/setup-host.sh --install-service`), `flk-check.timer` runs
the checks that have an interval, once a minute at most; a failing check
is tried every minute until it passes. `flk events` gets `check.failed`
when a check that passed stops passing and `check.recovered` when it's
back, once each, so a follower (`flk events -f --json`) can notify.

Checks only report: flk never restarts a machine over one. A check that
hasn't passed yet within its `grace_period` after a boot is "starting",
not failed, and machines that are stopped, stopping or paused for a
backup are left alone. A `log` check is a fact of the boot (found once,
it stays passed until the next boot); `tcp`, `http`, `udp` and `exec` are
tried again each time. `flk doctor` warns when checks have an interval
and the timer isn't installed or hasn't run for 5 minutes.

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
`flk logs --boot` prints everything since the machine last booted, from
flk's `--- flk: booting` line on, so a server that has written for days
still shows how it started: `flk logs --boot | head -n 100`, or
`flk logs --boot | grep -m1 'Server ready'`.

**Talk to the app.** `flk console ID` attaches to its serial console: what
you type goes to the app's stdin (Minecraft: `say hi`, `stop`). Leave with
Ctrl-b d (Ctrl-b Ctrl-b d inside tmux). Ctrl-C there doesn't stop the app.
For one command without attaching: `flk console ID --send "say hi"`; add
`--wait-log "REGEX"` to print the app's answer (scripts and agents too).

**Stop and start.** `flk stop` stops every machine of the app and keeps
them stopped, across reboots too; `flk start` brings them back and
`flk restart` restarts them one at a time. For one machine:
`flk machine stop|start|restart ID` (without an ID it lists the machines).

**Crashes.** When an app crashes or exits non-zero, flk restarts it (1s, 2s,
4s... apart, 10 times in a row at most; `[[restart]]` in flk.toml changes
that, `policy = "never"` turns it off). The log shows each restart. If it
gives up, `flk context` says so: read `flk logs -i ID`, fix, then
`flk machine start ID`. An app that exits cleanly (status 0) stays
stopped but counts as "should be running": `flk resume` starts it again.

**Reboots.** With `flk-machines.service` installed (`flk doctor` checks),
machines stop gracefully at shutdown and come back at boot. Without it:
`sudo {{SRC}}/setup-host.sh`, then `flk resume`. Machines run in flk's
tmux server, which `flk-tmux.service` owns (flk starts it when needed), so
none lives in a login session that shutdown kills first; doctor warns if
one does. Restarting that unit (needrestart does after some apt upgrades)
stops the machines gracefully and starts them again: a short outage, not
a lasting one.

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

(or: `flk config set backup_dir=/data/flk-backups backup_keep=7`, which
checks the values; `flk config show --host` prints the file.)

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
there), `flk volumes backups` shows where each backup's copy still is
(`--json`: a copy pruned there has `pruned_at`), and
`flk doctor` warns when a volume's newest copy is older than
`backup_copy_warn_days` (8).

**Files in a volume.** `flk files ls|cat|cp|rm|mkdir|chown` work on a
volume's files without mounting it or root (`VOL:PATH`, e.g.
`flk files cp ./server.properties world:/`). Reading works any time, and
on backups with `--backup`; writing needs the machine stopped and ends
with an e2fsck. Copied-in files get the target directory's owner (or
`--owner UID:GID`), not your host user's.

**A running machine's files, mounted here.** `flk ssh mount` puts a
directory of a running machine on this host, to edit with your own tools
as a user of the machine. Nothing listens in the guest (no sshd, keys or
port): flk starts the image's SFTP server through flk-agent, like
`flk exec`. Once per image, add that program to the Dockerfile and deploy:

    # Ubuntu, Debian
    RUN apt-get update \
     && apt-get install -y --no-install-recommends openssh-sftp-server \
     && rm -rf /var/lib/apt/lists/*
    # Alpine:  RUN apk add --no-cache openssh-sftp-server
    # Fedora:  RUN dnf install -y openssh-server

Once per host, install sshfs (`sudo apt install sshfs`; Arch `sshfs`,
Fedora `fuse-sshfs`). Then:

    flk ssh mount /home/dev ./dev-home --user dev   # PATH in the machine, DIR here
    ls ./dev-home                                   # its files, as yours
    flk ssh mounts                                  # every mount, and its state
    flk ssh unmount ./dev-home

`--user` is who reads and writes in the machine (a name from its
`/etc/passwd`, or a UID; default root); the files show as yours here.
`--read-only` for looking only. DIR is made if missing and must be empty.
The mount comes back by itself after a restart or deploy; while the
machine is stopped, files there fail with I/O errors. Destroying the
machine unmounts it, and a host reboot drops every mount (mount again).
`flk status` lists an app's mounts. It's for editing and copying, not
for a build or a database. A whole app to try it with:
`{{SRC}}/examples/devbox`. `flk files` is the other half: a stopped
machine's volume, without the guest.

**Root disk.** A machine's `/` is a copy of the release image with
`[flk] rootfs_extra_mb` (default 512) of free space, and it's replaced on
every deploy. When it fills up (`flk exec -- df -h /`),
`flk machine extend ID --size GB --restart` grows it in place and keeps
its files until the next deploy; raise `rootfs_extra_mb` and deploy to
have the room every time. See `flk help troubleshoot`, "The machine's
disk is full".

**Volume files.** `flk volumes extend NAME --size GB` grows a volume
(machine stopped), and `flk volumes move NAME --dir DIR` moves its file to
another disk (machine stopped). Backups are full copies on ext4; with the
volumes and `backup_dir` on one XFS (or btrfs) filesystem they're reflinks:
instant, and taking space only as the volume changes, which also makes
`pause` mode and `before_deploy` cheap.

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
