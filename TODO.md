# TODO

Open work on flk, the tool. Each entry says where the issue is caught
today, and where a fix could go. The order of work is in `PLAN.md`; what's
done (and the decisions behind it) is in `docs/history.md`; host and
game-server work is in `~/mud`.

## Reported by apps (index)

Apps file flk bugs in their own `BUGS.flk.md` (full text, cause and test
there). This index keeps them in view. At the start of a flk session, read
every `~/*/BUGS.flk.md` "Open" section and update this list. When one is
fixed, set its `Status: fixed in <commit>: ...` line in the app's file (the
workflow in its header), and the app's owner confirms. Last checked
2026-11-08.

| Report | Title | Where it's planned |
|---|---|---|
| mud #6 | Restarting flk-tmux.service stops every VM; nothing resumes them | R1: fixed in f7f9b4a (history.md); in effect on mud (units reinstalled, doctor clean 2026-11-08) |
| enshrouded #1 | rootfs build works in /tmp (a RAM tmpfs on mud) | R1: fixed, on main since 7f0317f (history.md) |
| valheim #2 | A failed build hides its own error and keeps no log | R1: fixed, on main since 7f0317f (history.md) |
| valheim #4 | A volume flk makes on its own stays root's (no mount point in the image) | R1: fixed, on main since 7f0317f (history.md) |
| valheim #5 | A before_deploy verify failure blocks the deploy that fixes a first start | R1: fixed, on main since 7f0317f (history.md) |
| valheim #6 | Boot waits 30s for TCP on a UDP-only internal_port | R1: fixed, on main since 7f0317f (history.md) |
| enshrouded #2 | before_deploy backups aren't copied to backup_copy_to | R1: fixed, on main since 7f0317f (history.md) |
| mud #4 | Recreate a missing rootfs.ext4 from the release image | R1: fixed, on main since 7f0317f (history.md) |
| mud #5 | Protect flk's podman images from `podman image prune -a` | R1: done, on main since 7f0317f (history.md) |
| valheim #1 | A health check for UDP-only servers (udp / a2s) | M6, checks |
| valheim #3 | A pre-deploy check the app owns (`[deploy] preflight`) | M6, checks |
| flkforge #1 | Any `type = "http"` check crashed deploy (NameError) | fixed, on main since 7f0317f; flkforge confirmed (history.md) |
| flkforge #2 | A log check ending in `$` never matched (`\r\r\n` line ends) | fixed, on main since 7f0317f; flkforge confirmed (history.md) |
| enshrouded #3 | No current health for a long-running machine; its boot scrolls out of `flk logs` | M6, checks (interval health); `logs --boot` and `log_max_mb` under Machines |
| minecraft #8 | Huge pages: fixed in 553b1a3; move to Resolved once a pool is tested | Machines |

## Reliability (PLAN.md R1)

Decided with Dayne on 2026-11-04. Each fix lands with the test its report
describes (tests/cases, `flkt-*` apps only), then the report's status line
is updated. Every change must be a no-op for apps that don't use it, or
plainly safer for them: main's `bin/flk` runs the real apps' boot, exit
hook and cron backups.

All of R1 is done and on main since 7f0317f (2026-11-05,
docs/history.md).

## Setup and host checks

- [ ] **Firewall and distro paths are untested on real hosts.** Only Ubuntu
  with Docker's firewall rules has been run end to end. These were written
  blind and need one pass each on a real host:
  - **ufw** (Ubuntu with `sudo ufw enable`): `setup-host.sh` adds
    `ufw route allow in on flkbr0` / `out on flkbr0` rules (`firewall_allow`);
    `flk-sanity.sh` checks them (`check_ufw`).
  - **firewalld** (Fedora default): `setup-host.sh` puts the bridge in the
    `trusted` zone; `flk-sanity.sh` checks it (`check_firewalld`).
  - Packages, sanity and `flk setup --fix` are covered on Ubuntu, Arch and
    Fedora by tests 60–62, as a normal user, with the install command
    sanity suggests (in a microVM: no KVM, bridge or firewall there, so not
    the rest).
  - *How to test:* on each host, start from a clean install, run
    `./flk-sanity.sh` and run the install command it suggests, then
    `sudo ./setup-host.sh`, `flk setup`, and `tests/run.sh`.
    What to look for: the VMs get network (the `test_guest_egress_nat_and_dns`
    and `test_reachable_on_host_lan_ip` tests), the forwarded ports work
    with the firewall on, `sudo ./setup-host.sh --down` removes the
    rules it added (`firewall_remove`), and sanity's checks pass or point at the right fix.
  - *Suggested hosts:* Fedora (covers firewalld and dnf), Arch (pacman), and
    Ubuntu with ufw enabled.
  - *Symptom if broken:* machines boot but have no network (another
    firewall's FORWARD drop wins over flk's nft accept), or forwarded host
    ports time out.
  - Real-host runs are host work, tracked in `~/mud`
    (`docs/flk-system-notes.md`). flk's part is below.

## For lazyflk (TUI, github.com/dayne/d.lazyflk; spec in its SPEC.md section 9)

lazyflk only uses flk's CLI, so what it needs are flk changes. Every new
JSON field is additive: lazyflk ignores unknown fields and treats missing
ones as "not supported by this flk", so nothing existing may change
shape. G1–G16 are done (`docs/history.md`; G15–G16 in git log).

- [ ] **Host settings from the CLI** (flk, 2026-10-15; nothing asked yet).
  New and additive: `flk config set KEY=VALUE...` writes
  `~/.config/flk/host.toml` (keys checked; bind/address validated before
  the file is replaced), and `flk config show --host` prints
  `{"file", "settings"}`. lazyflk could offer a host settings form (e.g.
  backup_dir from doctor's "no backup_dir set" warning, whose hint is now
  `flk config set backup_dir=...`). `flk setup --fix` also exists.
  Handed over: a note is in lazyflk's `TODO.md` ("From flk 21ffec9 and
  7cb3ddb"); close this when lazyflk has it.

## For flkforge (image wizard, ~/d.flkforge; PLAN.md M6)

flkforge (at its M4 on 2026-11-05: the wizard, a CLI for agents, flk-run
and 52 snippets) is a CLI and TUI wizard that writes a Dockerfile and
flk.toml from reusable snippets, explaining each choice as it goes. Where
flk lacks something below it works around it today (a seeding script,
parsing `help --all` text), so each item lets it drop a workaround. Like lazyflk it uses only flk's CLI, so these are
flk changes, all additive and opt-in. flkforge records what it needs in
its own `BUGS.flk.md`. The setpriv entry under Machines came out of the
same review.

- [ ] **`flk build`: build and inspect without deploying.** Today an image
  is only built by `deploy`, which needs a registered app and touches
  machines. flkforge's `check` (and anyone writing a Dockerfile) wants:
  `flk build [DIR] [--json]` builds the image and rootfs as deploy would,
  keeps no release, and reports what flk will do with it: `user`, `cmd`,
  `entrypoint`, `workdir`, `has_sh` (shell init or the static one),
  `can_switch_user` (setpriv / chroot --userspec / agent), whether the agent
  went in, image and rootfs sizes, and the problems below as warnings. Exit
  1 on a build failure, with podman's error as in deploy.
- [ ] **Image warnings at build and deploy.** Things flk can see but only
  logs at boot today, or not at all. Each should be a warning with its fix,
  in `flk build`, `deploy` and `flk config show`:
  - non-root USER with no way to switch (see Machines);
  - no CMD/ENTRYPOINT (the machine boots `/bin/sh` and exits);
  - a `[[mounts]]` destination the image already has files in (the
    volume hides them);
  - USER non-root and the volume's root owned by root with no mount point
    owned by that user in the image (valheim.flk BUGS #4): suggest
    `flk volumes create ... --owner UID:GID`.
- [ ] **Checks, designed as one piece.** Three new kinds share config,
  events, `Next:` lines and rollback, so design them together (decided
  2026-11-04):
  - `type = "exec"`: `command = ["sh", "-c", "..."]`, `user`: run a
    command in the guest through the agent, and pass on exit 0. Deploy
    checks today see only ports and log lines. This lets a release prove
    the volume is mounted, the tool runs, or the app's own health command
    passes, and roll back otherwise. Needs the agent (no Go, no exec
    check: say so in config show). flkforge snippets would carry these as
    their smoke tests.
  - `type = "udp"` (`port`, optional `send`/`expect`) and the shorthand
    `type = "a2s"` (Steam's A2S_INFO, handling the challenge reply) for
    UDP-only game servers (valheim #1: first check that Valheim answers
    A2S when `-public 0`).
  - `[deploy] preflight = "CMD"`: a host command run in the flk.toml's
    directory before the build (env `FLK_APP`, `FLK_RELEASE` = the next
    version). A non-zero exit stops the deploy with `deploy failed;
    machines unchanged` and the command's last line, before any build;
    `flk deploy --no-preflight` skips it (valheim #3: a stale Steam pin
    shouldn't cost a 2GB download).
  - Health while running (enshrouded #3, 2026-11-08): checks run only
    during a deploy, so `flk status` can't say whether a machine is up now.
    An opt-in `interval = "5m"` per check, the last result per machine in
    `flk status --json` (`checks: {NAME: {ok, at, since}}`), and
    `check.failed` / `check.recovered` events on a change. A `log` check
    that passed for this boot stays passed (a boot fact; today it reads the
    last 256KB since the boot marker, too little for a chatty app); tcp,
    http, udp/a2s and exec re-run. The game repos' status tools would stop
    scraping logs.
- [ ] **Seed a new volume from the image.** `[[mounts]] seed = true`
  (flk only): when the volume is empty on first mount, copy what the image
  has at `destination` into it first, as Docker does with a named volume.
  This solves home directories on a volume (dev boxes) and config
  directories the program ships with. Could be done host-side at
  `volumes create`/first deploy (`--from-dir` from the rootfs), which
  needs no guest change.
- [ ] **flk.toml keys as JSON.** `flk help --all --json` lists commands
  but not config keys. flkforge's `explain KEY`, its rules and its "does
  this flk support X" checks need them: a `config_keys` array (key, type,
  default, flk-only, one-line doc, the flk version it appeared in) built
  from the same source as the Config section of `share/guide.md`. That
  would also let `tests/cases/00-config.sh` check that the guide and the
  parser agree.
- [ ] **Ideas, not yet asked for:** `flk config show --file PATH` (check a
  file outside cwd); a `flk ssh config APP` that prints an
  `~/.ssh/config` entry for editors' remote modes (when the image runs
  sshd); per-app LAN addresses for dev boxes are M5's managed extra
  addresses, not a separate feature.

## LAN addresses and failover (PLAN.md M5)

Forwarded ports answer on every address the host owns (the DNAT rule
matches `fib daddr type local`), or only on `bind` addresses (host.toml,
`[flk] bind`). To build:

- [ ] **Managed extra addresses.** Instead of hand-editing netplan, flk-net
  could add/remove listed LAN addresses (`ip addr add ... ` + gratuitous
  ARP) from a root-owned config; doctor checks nobody else answers ARP for
  them (`arping -D`) and that they're outside the DHCP pool (warn only).
- [ ] **keepalived (VRRP) hooks.** A floating address held by the active
  host: `flk host activate` / `flk host deactivate` (resume or stop-all
  the apps tied to that address) for keepalived's notify scripts, and
  `flk host check --address IP` as its health check (machines running,
  ports mapped). A sample keepalived.conf in `share/help/`.
- [ ] **Data for failover.** The hard part: the standby needs the volumes.
  Steps: copy volumes on a clean stop (`flk volumes sync --to HOST`,
  rsync of the stopped sparse file), then maybe DRBD or shared storage.
  Must make split brain impossible: never start an app whose volume
  another host may hold (a lease/fence, or refuse unless this host holds
  the floating address).

## Snapshots

- [ ] **Volume snapshots.** Backups and extend are done; instant
  snapshots need volumes on a reflink filesystem (an XFS LV for flk's
  volumes: `cp --reflink` is instant, so `pause` mode freezes the VM for
  milliseconds) or LVM thin volumes (root helper). Then: backups to the
  NAS / a second drive as just another `--to`, or rsync/restic of
  backup_dir; an in-guest `sync`/fsfreeze through `flk exec`.
- [ ] **Snapshots of machines** (Firecracker snapshot/restore): suspend and
  sub-second resume.

## Machines

- [ ] **A non-root USER runs as root on busybox images.**
  `share/init.sh` (`start_app`) switches to the image's USER with
  util-linux `setpriv`, else `chroot --userspec`, else it logs
  `WARNING: can't switch to user ...; running as root` and runs the app as
  root. Alpine and other busybox images have neither, so a Dockerfile
  with `USER app` runs as root there, and the only sign is one line in
  the boot log. (Found 2026-11-04 in the flkforge design review.) Worse
  until the R1 valheim #4 work: Alpine 3.20's busybox *has* a `setpriv`
  applet, without `--reuid`; init called it and the app died at boot.
  init now checks for `--reuid` first (so: root, with the warning).
  - *Fix:* the agent already switches users when it's PID 1
    (`agent/init.go`, `lookupUser`). Give it a mode init.sh can exec,
    e.g. `/flk/agent run-as USER -- /flk/cmd` (resolves names from the
    image's /etc/passwd and sets the groups), and try it after setpriv and
    before chroot. Without the agent (no Go on the host), keep today's
    order. Also warn at build/deploy (For flkforge: image warnings) so it
    isn't only in the boot log.
  - *Real apps:* this changes behaviour on their next deploy only if
    their image has a non-root USER and no setpriv. From their
    Dockerfiles: the four games are Ubuntu-based (util-linux, so setpriv)
    and mqtt-flk (Alpine) sets no USER. Confirm with
    `flk -a APP exec sh -c 'cat /flk/user; command -v setpriv'` before
    merging.
  - *Test:* `43-volume-owner` boots an Alpine image with `USER app` and
    expects the fallback warning today; with the fix, its CMD should
    print `id -u` = 1100, not 0.

- [ ] **flk's tmux server keeps its groups.** The server now stays up when idle
  (for the exit hook). If it lacks `kvm` and no machines run, flk restarts it
  by itself; with machines running it still says to stop them and run
  `tmux -L flk kill-server`.
- [ ] **`flk logs --boot`** (enshrouded #3): the lines since the latest
  `--- flk: booting` marker, reading `console.log.1` too when the boot
  started there. `flk logs` is `tail -n N` of `console.log` only
  (`lib/flk/cli/console.rb`), so a chatty app's boot scrolls out, and is
  gone at the 10MB rotation. Small, additive. Lower value, same report:
  `[flk] log_max_mb` per app (FLK_LOG_MAX_MB is host-wide).
- [ ] **Huge pages on a real pool.** `[[vm]] huge_pages = "2M"` is built
  and tested without a pool; booting on one needs root to reserve it
  (`tests/cases/45-hugepages.sh` runs when a pool exists).
