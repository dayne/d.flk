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

## Reliability

- [ ] **No restart policy.** A crashed app stays down. Fly's
  `[[restart]] policy = "always" | "on-failure" | "no"` could hang off the
  tmux `session-closed` hook (`flk ports reap`).
- [ ] **Forwarded ports on 127.0.0.1** (from the bug report, optional part):
  loopback is skipped on purpose; making it work needs `route_localnet`
  on the bridge path, a host-wide security trade-off. `flk proxy` covers
  TCP; nothing covers UDP yet.
- [ ] **Deploys don't wait for health.** A machine that never listens only
  gets a warning, and the roll continues. Stop the roll instead (Fly's
  `[[http_service.checks]]` / `[checks]` are a model).

## Config and releases

- [ ] **Typos in flk.toml are silently ignored.** Unknown keys are dropped on
  purpose (fly.toml compatibility), so `kill_timout = 60` does nothing.
  Warn on keys that are neither flk's nor known Fly keys, in `deploy` and
  `config show`.
- [ ] **No rollback.** `flk releases` lists history but there's no
  `flk deploy --release vN` / `flk releases rollback`. Only the last two
  rootfs images are kept.

## For lazyflk (TUI, spec in lazyflk/SPEC.md section 9)

- [ ] **G1: read commands can block on a deploy.** `apps list` / `status` /
  `ports` reap exited machines, and that waits for the global lock a deploy
  holds for its whole run (12.5s observed). Take it non-blocking and skip.
- [ ] **G2: the app's config dir isn't recorded.** Store the flk.toml path in
  `app.json` on launch/deploy; expose `config_path` in status/context JSON.
- [ ] **G3: no non-interactive console input.** `flk console ID --send TEXT`.
- [ ] **G4: no per-machine CPU/memory.** `flk machine stats [--json]`, `pid`
  in machine JSON.
- [ ] **G5: context always runs doctor.** `flk context --all --json --no-host`
  for cheap polling.
- [ ] **G6: JSON has no schema version.** `"schema": 1` plus a compatibility rule.
- [ ] **G7: no events.** Later: `flk events --json`.
- [ ] **G8: no disk breakdown.** `flk disk [--json]`: bytes per app and
  category (release images, rootfs copies, volumes, logs), sparse-aware.

## Bigger features

- [ ] **Exec into a machine.** A small vsock agent in the guest for a real
  `flk ssh console` and `flk ssh console -C "cmd"` (like Fly's hallpass).
- [ ] **`APP.internal` DNS** between machines (dnsmasq on the bridge, fed
  from machine records).
- [ ] **Volume snapshots, extend, backup.**
- [ ] **Snapshots of machines** (Firecracker snapshot/restore): suspend and
  sub-second resume.
- [ ] **Static init** (Go/Rust) so distroless/scratch images boot without `/bin/sh`.

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
- [x] Admin help at every stage: `flk context --all` (host overview),
  `flk help TOPIC` guides (cheatsheet, install, first-app, operate,
  troubleshoot, uninstall; also in `help --all`), `Next:` lines after
  commands that change things, `flk completion bash`, and absolute paths
  to `setup-host.sh` in every hint.
- [x] From the minecraft.flk bug report: `/dev/fd`, `/dev/std*` in the guest;
  the app's stdin is the serial console (`[flk] stdin = "null"` to opt out);
  volumes with `--path` / `--from-dir` / `import` that flk never deletes;
  forwarded ports say they don't answer on 127.0.0.1 and show the address
  that does.
- [x] From the bug report, part 2: a stop unmounts volumes and remounts the
  rootfs read-only before the guest reboots (no journal replay; host tools
  see a clean volume). `flk-machines.service` gets `RequiresMountsFor=` the
  state dir and every external volume's dir; doctor warns when a volume's
  disk isn't covered. Volumes outside the state dir count as external even
  without the flag (a hand-edited path is never deleted).
- [x] No more image and log leaks: release pruning and `apps destroy` untag
  `flk.local/APP:vN`; `flk apps prune` clears tags of apps already gone
  (doctor warns about them); `console.log` rotates to `console.log.1` past
  `FLK_LOG_MAX_MB` (libexec/flk-logpipe).
- [x] Reboots: machines record `desired_state`; `flk resume` starts what should
  run, `flk stop-all` stops everything gracefully and keeps it marked;
  `--install-service` adds `flk-machines.service` (resume at boot, stop-all
  at shutdown); doctor warns when it's missing.
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
