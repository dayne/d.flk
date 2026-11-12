# Troubleshooting

Start with `flk context` (or `flk context --all`) and `flk doctor`: most
problems show up there with the fix. Then find the symptom below.

**A machine is stopped but should be running**
- Why it stopped: `flk logs -i ID -n 200`. The last `[flk-init]` line has
  the app's exit status.
- Bring it back: `flk machine start ID` (or `flk resume` for all of them).
- It stops right away again: the app itself is exiting. Check its command
  (`flk config show`, `[experimental] cmd`) and its env/secrets.
- "restart policy gave up": it crashed `retries` times in a row (each
  restart is noted in `flk logs`). Fix the cause, then `flk machine start ID`.
- It keeps coming back after you stopped it from inside (an in-game `stop`
  that exits non-zero): that's the restart policy; use `flk machine stop ID`,
  or set `[[restart]] policy = "never"`.
- Machines that exit aren't noticed (ports stay mapped, no restarts):
  `flk doctor` checks flk's exit hook; `flk resume` reinstalls it.

**Deploy fails**
- `short-name ... did not resolve`: run the one-liner flk prints, or use a
  full image name (`docker.io/library/ruby:3.3`).
- `not enough free volumes`: `flk volumes create NAME --size N`, one per machine.
- `a backup of its volume is running`: a `stop`-mode `flk volumes backup`
  has the machine down; it starts it again when the copy is done.
- A backup reports `fsck: repaired` or `errors` (e2fsck's output is in
  BACKUP.fsck.log; a journal replay alone counts as clean): the app was
  writing during a `live` copy, or the volume itself is damaged. Add `pre`
  hooks that make it save and stop writing, or use `mode = "pause"` or the
  default `stop`; if a `stop` backup shows it too, check the volume
  (machine stopped): `e2fsck -f FILE`. Older backups are kept.
- `vN failed its health checks`: the machine went back to its previous
  release and is running. `flk releases` shows which check failed;
  `flk logs -i ID --no-tail` shows why. To debug the new release in
  place: `flk deploy --no-rollback`. A check that's too strict: raise its
  `grace_period` (slow starts, e.g. a big world).
- `The interrupted build left N build containers`: Ctrl-C during the
  image build leaves podman's working containers mounted; run the
  `buildah rm ...` it prints (doctor reports ones older than an hour).
- `tap pool exhausted` / `flktapN missing`: `sudo {{SRC}}/setup-host.sh`
  (with `FLK_TAPS=32` for more machines).
- `build failed; machines unchanged (still on vN)`: the build (or a check
  before the roll) failed, and no machine was stopped or changed: they
  still run vN. Fix the cause shown above it ("The build said:") and deploy
  again. The build's whole output is in the `Build log:` file it names
  (also in the `deploy.failed` event's `log`), so there's no need to
  build again to read it: `flk releases log` prints the newest
  (`--failed`, or a release `vN`).
- `not enough space to build the rootfs in DIR`: turning the image into
  the release's disk needs about twice the image's size, free next to
  flk's images (`flk disk` shows where they are and what they take). Free
  space there (`flk images`, `flk apps prune`); `/tmp` isn't used.
- `groupadd: GID '1000' already exists` (or `useradd: UID 1000 is not
  unique`): ubuntu:23.04 and later ship user `ubuntu` as 1000:1000. Rename
  it (`usermod -l NEW -d /home/NEW -m ubuntu && groupmod -n NEW ubuntu`) or
  remove it first (`userdel -r ubuntu`).
- The app can't write to its volume (`Permission denied` under the mount
  point): the volume's root is owned by root. A volume made with
  `flk volumes create` takes the owner of the mount point in the image on
  its first use, or else the image's USER (the deploy says which); for an
  older one, one that had data already, or another owner:
  `flk machine stop ID`, `flk files chown UID:GID VOL:/`, start again
  (or create volumes with `--owner UID:GID`).
- `nothing listening on IP:PORT after 30s`: the app is up but not on
  `internal_port`. Check `flk logs`, and that it listens on 0.0.0.0, not
  127.0.0.1.

**The machine's disk is full** (`No space left on device`, `/` at 95%)
- Which disk: `flk exec -- df -h`. `/` is the root disk (a copy of the
  release image); each volume is its own line at its mount point.
  `flk machine list --json` has the root disk's size as `root_disk_mb`.
- `/` is full, and what's on it should stay (tools installed since the
  deploy, say): `flk machine extend ID --size GB --restart` stops the
  machine, grows the root disk and its filesystem to GB in all, and
  starts it again; without `--restart`, stop it first. Files on `/` are
  kept. The new room takes host disk only as it's used.
- That lasts until the next deploy or rollback: both start from the
  release image again, at its own size, without anything written to `/`
  since. For more room on every deploy, set `[flk] rootfs_extra_mb` in
  flk.toml (MB free on `/` beyond the image's files, default 512; the
  extend prints how much to raise it by) and `flk deploy`.
- What keeps filling `/`: `flk exec -- du -xm -d 2 / | sort -n | tail`
  (MB per directory, biggest last).
  Tools the app always needs belong in the Dockerfile (the root disk then
  grows with the image); data it writes belongs on a volume
  (`[[mounts]]`), which outlives deploys.
- A volume is full: `flk machine stop ID`, `flk volumes extend NAME --size GB`,
  `flk machine start ID`.
- `flk machine extend` or `volumes extend` says `e2fsck found errors it
  couldn't fix`: the filesystem is damaged and was left at its old size.
  For a root disk, `flk deploy` makes a new one from the image.

**Can't reach the app**
- From the host: use the machine IP (`flk status`), `http://IP:PORT`.
- Via a host port: `flk ports`. "blocked" says why (below 1024, or a
  host process already listens there). "waiting" means another machine has
  it. Nothing listed: add `[flk] http_port` or `[[services.ports]]`, then deploy.
- 127.0.0.1 never works for forwarded ports: use the host's LAN IP (shown
  by `flk ports`), or `flk proxy PORT`.
- Works on one host address but not another: the app (or the host
  settings) has `bind`, so `flk ports` shows `ADDRESS:proto/port` and only
  that address answers. An address `flk doctor` says isn't on this host
  answers nothing.
- From another computer: check the host firewall allows that port
  (`flk-sanity.sh` checks ufw and firewalld).

**The machine has no network** (DNS or downloads fail inside it)
- `flk doctor`: bridge, taps and ipv4 forwarding.
- Another firewall (Docker, ufw, firewalld) may be dropping forwarded
  traffic: `{{SRC}}/flk-sanity.sh` checks, `sudo {{SRC}}/setup-host.sh` fixes.

**The app misbehaves only under flk**
- Process substitution, `/dev/stdout`, `/dev/fd`: supported.
- The app reads stdin: it's the serial console (`flk console`). If it acts
  oddly because stdin is a terminal, set `[flk] stdin = "null"`.
- Distroless/scratch images don't boot: images without `/bin/sh` boot with
  flk-agent as init, which flk builds with Go. Without Go the deploy says
  "no flk-agent to boot it with"; install Go (see `flk help install`).

**Can't start machines: /dev/kvm, groups**
- `flk doctor` says `/dev/kvm` isn't accessible: `sudo {{SRC}}/setup-host.sh`,
  then log out and back in.
- "flk's tmux server started before you joined the kvm group": stop the
  machines, then `tmux -L flk kill-server`.

**After a reboot nothing runs**
- `flk doctor` "boot service": `sudo {{SRC}}/setup-host.sh --install-service`.
- Now: `sudo {{SRC}}/setup-host.sh`, then `flk resume`.
- Machines were killed at shutdown, not stopped (`flk events`: "the host
  went down with it running"): doctor's "not a flk service" warning says
  how to move them; "predates flk-tmux.service":
  `sudo {{SRC}}/setup-host.sh --install-service`.

- After restoring flk's state dir from a backup that skipped the
  machines' `rootfs.ext4` (copies of the release images): `flk resume`
  makes each missing one again from its release image and says so. "root
  disk is missing, and so is vN's image": `flk deploy`.

**After an apt upgrade every machine is stopped**
- needrestart restarted `flk-tmux.service`, which stops the machines
  gracefully first. Units installed before it learned to resume after a
  restart leave them stopped. Now: `flk resume`. For next time:
  `sudo {{SRC}}/setup-host.sh --install-service` (doctor warns until then).

**Where things are**
- Machine files: `{{ROOT}}/apps/APP/machines/ID/` (console.log,
  firecracker.log, machine.json, vm.json).
- Exit hook errors: `{{ROOT}}/hooks.log`.
- Start over with one app: `flk apps destroy APP --yes`.
