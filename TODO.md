# TODO

Open work on flk, the tool. Each entry says where the issue is caught
today, and where a fix could go. The order of work is in `PLAN.md`; what's
done (and the decisions behind it) is in `docs/history.md`; host and
game-server work is in `~/mud`.

## Setup and host checks

- [ ] **Firewall and distro paths are untested on real hosts.** Only Ubuntu
  with Docker's firewall rules has been run end to end. These were written
  blind and need one pass each on a real host:
  - **ufw** (Ubuntu with `sudo ufw enable`): `setup-host.sh` adds
    `ufw route allow in on flkbr0` / `out on flkbr0` rules (`firewall_allow`);
    `flk-sanity.sh` checks them (`check_ufw`).
  - **firewalld** (Fedora default): `setup-host.sh` puts the bridge in the
    `trusted` zone; `flk-sanity.sh` checks it (`check_firewalld`).
  - **dnf package names**: the install command `flk-sanity.sh` suggests on
    Fedora (the `PKG` table) has never been run. Arch and Ubuntu packages,
    sanity and `flk setup --fix` are covered by tests 60/61 (in a microVM:
    no KVM, bridge or firewall there, so not the rest).
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
- [ ] **A Fedora install test** (`tests/cases/62-install-fedora.sh`,
  `tests/apps/install-fedora`): `tests/install-run.sh` already takes a
  distro; add `fedora` → dnf there. That runs the dnf package names from
  sanity's `PKG` table, the one distro path no test touches yet.
- [ ] **Install tests run as root.** In the 60/61 VMs everything runs as
  root, so the steps a new user actually hits aren't covered: sudo with a
  password, joining `kvm`, `~/.local/bin` not on PATH yet (setup's PATH
  hint), a user-level podman. Run steps 3–7 of `install-run.sh` as a
  created user (`useradd -m`, `runuser -l`).

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

- [ ] **flk's tmux server keeps its groups.** The server now stays up when idle
  (for the exit hook). If it lacks `kvm` and no machines run, flk restarts it
  by itself; with machines running it still says to stop them and run
  `tmux -L flk kill-server`.
- [ ] **Huge pages on a real pool.** `[[vm]] huge_pages = "2M"` is built
  and tested without a pool; booting on one needs root to reserve it
  (`tests/cases/45-hugepages.sh` runs when a pool exists).
