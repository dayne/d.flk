# TODO

Known rough edges, found while getting flk running on real hardware.
Each entry says where the issue is caught today, and where a fix could go.

## Setup and host checks

- [ ] **Podman short image names.** On Ubuntu/Debian, podman has no
  `unqualified-search-registries`, so `FROM ruby:3.3` fails with
  "short-name did not resolve". `alpine` only works because podman ships an
  alias for it. Most real Dockerfiles (Minecraft ones included) use short names.
  - *Caught today:* `flk-sanity.sh` warns (`check_short_names`), and the README
    quick start shows the one-line fix.
  - *Fix options:* have `flk setup` offer to write
    `~/.config/containers/registries.conf` (user-level, no root), and/or have
    `flk deploy` spot the "short-name ... did not resolve" error and print the fix.
    Watch out: a user-level registries.conf replaces the system one, so merge,
    don't overwrite.
- [ ] **ufw and firewalld handling is untested on real hosts.** `setup-host.sh`
  adds `ufw route allow` rules or puts the bridge in firewalld's trusted zone.
  Only the Docker path existed before. Test both, and the matching
  `flk-sanity.sh` checks, on a host where they're enabled.
- [ ] **pacman/dnf package names** in `flk-sanity.sh` haven't been tried on Arch
  or Fedora.

## Port forwarding

- [ ] **No watcher for machines that exit on their own.** `flk status`,
  `flk ports`, `flk machine list` and `flk apps list` now reap them and resync,
  but if no flk command runs, the port stays mapped to a dead IP. A small
  watcher (or a systemd path unit on the pid files) would close the gap.
- [ ] **`[http_service]` isn't exposed.** It means public 80/443 on Fly. Maybe a
  `[flk] http_port = 8080` to forward it to a chosen host port.

## Machines

- [ ] **`flk console` from inside tmux** is now a nested tmux (flk has its own
  tmux server), so detach is `Ctrl-b Ctrl-b d`. flk prints that hint, but a
  different prefix for flk's server would be friendlier.
- [ ] **flk's tmux server keeps its groups.** If VMs are running when you're added
  to a new group (e.g. `kvm` after a reinstall), restarts fail until
  `tmux -L flk kill-server`. flk detects this and says so.

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
- [x] `flk doctor --json`; `flk-sanity.sh` reads that instead of ✔/✘ lines.
  Doctor also reports the port helper (missing / needs a password /
  predates the host port guard) as a warning.
