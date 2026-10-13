# Running apps day to day

**See what's there.** `flk context --all` lists every app, machine, IP and
port on the host, and what needs attention. In an app directory,
`flk context` and `flk status` cover that app; elsewhere add `-a APP`.

**Ship a change.** Edit code or `flk.toml`, then `flk deploy` from the app
directory. Each deploy is a new release (`flk releases`); machines are
updated one at a time. There's no rollback command yet: check out the old
code and deploy again.

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

**Disk.** Everything is under `{{ROOT}}`: two release images per app,
volumes (unless created with `--path`), logs. `flk apps prune` removes
images of destroyed apps. To back up a volume, stop its machine and copy
the file (`flk volumes list --json` shows the path): a stop unmounts it
cleanly, so the copy is consistent. Volumes on other disks (`--path`):
put the disk in `/etc/fstab` (without `nofail`) and reboots mount it before
machines start, and stop machines before unmounting it. `flk doctor` warns
if a disk isn't covered, e.g. a `nofail` or network mount: then re-run
`sudo {{SRC}}/setup-host.sh --install-service` once.

**Updating flk.** `git -C {{SRC}} pull`, then `flk setup` for a newer
firecracker or kernel. Running machines pick changes up on their next
deploy or restart.

When something's wrong: flk help troubleshoot
