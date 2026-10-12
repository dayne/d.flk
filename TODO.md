# TODO

Known rough edges, found while getting flk running on real hardware.
Each entry says where the issue is caught today, and where a fix could go.

## Setup and host checks

- [ ] **Firewall and distro paths are untested on real hosts.** Only Ubuntu
  with Docker's firewall rules has been run end to end. These were written
  blind and need one pass each on a real host:
  - **ufw** (Ubuntu with `sudo ufw enable`): `setup-host.sh` adds
    `ufw route allow in on flkbr0` / `out on flkbr0` rules (`firewall_allow`);
    `flk-sanity.sh` checks them (`check_ufw`).
  - **firewalld** (Fedora default): `setup-host.sh` puts the bridge in the
    `trusted` zone; `flk-sanity.sh` checks it (`check_firewalld`).
  - **dnf / pacman package names**: the install commands `flk-sanity.sh`
    suggests on Fedora and Arch (the `PKG` table) have never been run.
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

## Port forwarding


## Machines


- [ ] **`flk console` from inside tmux** is now a nested tmux (flk has its own
  tmux server), so detach is `Ctrl-b Ctrl-b d`. flk prints that hint, but a
  different prefix for flk's server would be friendlier.
- [ ] **flk's tmux server keeps its groups.** The server now stays up when idle
  (for the exit hook). If it lacks `kvm` and no machines run, flk restarts it
  by itself; with machines running it still says to stop them and run
  `tmux -L flk kill-server`.

## Done (for reference)

- [x] Graceful stop: `/flk/init` now disables the kernel's Ctrl-Alt-Del hard
  reboot, so stop sends the app SIGTERM instead of pulling the plug.
- [x] Guest kernel lookup for Firecracker ≥ v1.16: CI moved to dated
  `firecracker-ci/YYYYMMDD-*` dirs.
- [x] Firecracker runs on flk's own tmux server (`tmux -L flk`), not the user's.
- [x] `kill_timeout` honoured; `[[services.ports]]` forwarded to the host.
- [x] Host port guard: ports below `FLK_MIN_PORT` (default 1024) and ports a
  host process listens on (non-loopback) are refused, in flk *and* in the
  root helper. `flk ports` shows them as blocked.
- [x] Machines that exit on their own are reaped by the listing commands, and
  their host ports are handed to the next machine or dropped.
- [x] Tests forward a random free host port instead of 25565.
- [x] `kill_timeout` capped at 300s (config rejects more; stop clamps old
  machines' stored value).
- [x] Agent-friendly CLI: one command table drives argument parsing (unknown
  options/arguments are errors, with did-you-mean) and all help: `flk help`,
  `flk help CMD`, `flk CMD --help`, `flk help --all [--json]`. `flk context`
  shows the current state with next steps. `--json` on listing commands.
  `logs` follows only in a terminal; `apps destroy` and `console` never wait
  on a missing terminal.
- [x] Podman short image names: `flk doctor` / `flk context` warn when podman
  has no search registries, and a build or pull that fails with
  "short-name ... did not resolve" prints the fix: a user-level drop-in
  (`~/.config/containers/registries.conf.d/`, which adds to the system config
  instead of replacing it), or the full image name.
- [x] Machines that exit on their own are noticed immediately: a
  `session-closed` hook on flk's tmux server runs `flk ports reap` (no
  daemon); `exit-empty off` keeps the server alive for it.
- [x] `[flk] http_port = N` forwards `[http_service] internal_port` to host
  port N, with the same guard as `[[services.ports]]`; duplicate host ports
  in one config are rejected.
- [x] Deploy checks volumes and free taps before building, and again under
  the lock before recording the release; a deploy that fails before then
  leaves no release and no image behind. `scale count` checks first too.
- [x] `flk doctor --json`; `flk-sanity.sh` reads that instead of ✔/✘ lines.
  Doctor also reports the port helper (missing / needs a password /
  predates the host port guard) as a warning.
