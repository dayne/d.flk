---
title: flk
sub_title: the fly.io workflow for local Firecracker microVMs
author: Dayne Broderson
---

<!--
  Present: presenterm docs/flk-slides.md (a terminal of 100x30 or more)
  The "Live" slide runs its command only with: presenterm -x docs/flk-slides.md
  Code blocks render in a fixed-width box: keep their lines under ~56 chars.
-->

What flk is
===

`fly launch`, `fly deploy`, `fly machine`, `fly volumes`, `fly secrets`,
on your own Linux box, backed by **Firecracker microVMs**.

<!-- pause -->

- Reads your **`fly.toml` unchanged**: the same app directory deploys to
  Fly or to your laptop
- Each machine is a real VM: its own kernel, IP, volumes and secrets
- **No daemon.** Machines run under flk's own tmux server
- **Root once**, for host networking (`setup-host.sh`), then never again

<!-- pause -->

Ruby (stdlib only) for the logic, bash for the plumbing, and a small static
Go agent inside each guest.

<!-- end_slide -->

Why
===

<!-- column_layout: [1, 1] -->

<!-- column: 0 -->

### The itch

- Game servers at home (Minecraft, Vintage Story) with players on them
- Fly's model is good: releases, machines, volumes, secrets
- Containers alone don't give per-app kernels, clean stops, or volumes you
  can back up as files

<!-- column: 1 -->

### The bar

- Same `fly.toml`, same commands
- Every hint names the fix
- Safe for players: deploys roll back, backups are verified
- Usable by **AI agents** as well as people

<!-- reset_layout -->

<!-- end_slide -->

Concept map
===

| fly.io               | flk                                        |
|----------------------|--------------------------------------------|
| `fly.toml`           | `flk.toml`, or `fly.toml` as-is            |
| builder / registry   | local podman build → ext4 rootfs           |
| Machine              | Firecracker VM in `tmux -L flk`            |
| init (PID 1)         | `/flk/init` (sh), or the static agent      |
| 6PN network          | bridge `flkbr0`, 172.30.0.0/24, NAT        |
| Volume               | sparse ext4 file on virtio-blk             |
| Secrets              | per-boot config drive (0600)               |
| `fly ssh console`    | `flk ssh console` / `flk exec` (vsock)     |
| `APP.internal`       | `/etc/hosts`, opt-in                       |

<!-- end_slide -->

<!-- jump_to_middle -->

Getting started
===

<!-- end_slide -->

Setting up a host
===

```bash
./flk-sanity.sh         # what to fix next
sudo ./setup-host.sh    # once: bridge, taps, NAT
sudo ./setup-host.sh --install-service   # at boot

ln -s "$PWD/bin/flk" ~/.local/bin/flk
flk setup               # firecracker + kernel, no root
flk doctor              # "Ready to fly, locally."
```

<!-- pause -->

Lost? `flk context` says what flk sees and **what to do next**.
`flk help install` walks the same steps.

<!-- end_slide -->

A first app
===

```bash
cd examples/hello
flk launch --no-deploy    # register the app
flk volumes create data --size 1
flk secrets set API_TOKEN=s3cr3t --stage
flk deploy                # build, then roll machines
curl http://172.30.0.10:8080/
```

<!-- pause -->

Every key flk reads, annotated: `examples/reference/flk.toml`
(a test keeps every example warning-free).

`flk config show` prints what flk understood; a typo gets
*"did you mean kill_timeout?"*.

<!-- end_slide -->

How a deploy works
===

```
Dockerfile ─podman build─▶ image ─▶ rootfs.ext4
                     (+ /flk/init, cmd, flk-agent)

each machine, one at a time:
  stop ─▶ copy rootfs ─▶ config drive ─▶ boot
                                          │
                                   health checks
                                    ┌─────┴─────┐
                                  pass        fail
                                    │           │
                              next machine  back to vN-1
```

<!-- pause -->

- The rootfs is ephemeral per release; data lives on volumes
- Stop = Ctrl-Alt-Del → SIGTERM to the app → poweroff (`kill_timeout`)

<!-- end_slide -->

Deploys you can trust
===

- `[checks.NAME]`: `tcp`, `http`, or flk's own `log` (a console line)
- A failing machine **goes back to its previous release**, and the deploy stops
- `flk releases rollback [vN]`, and `--with-volumes` from pre-deploy backups

<!-- pause -->

New: a failed build says, last, that **nothing changed**:

```
Error: build failed; machines unchanged (still on v3)
Next: flk deploy (after fixing the build)   or: flk status
```

<!-- speaker_note: Someone stopped their running machine because they thought a failed build had touched it. Now the last line says it didn't. -->

<!-- end_slide -->

<!-- jump_to_middle -->

Day to day
===

<!-- end_slide -->

Running apps
===

```bash
flk stop | start | restart   # the whole app (new)
flk machine stop ID          # one (no ID: lists)
flk logs -f                  # app output and boot
flk console                  # type to it; Ctrl-b d
flk console --send "say hi" --wait-log "hi"
flk exec -- ls /data         # over vsock
flk ssh console              # a shell
flk events -f                # what happens, live
```

<!-- pause -->

Crashes restart with backoff (`[[restart]]`); flk's own stops never count.
`flk resume` / `flk stop-all` are what the boot service runs.

<!-- end_slide -->

Networking
===

- Machine IPs are **reachable from the host**: `curl http://172.30.0.10:8080`
- `[[services.ports]]` forward from every host address (or `[flk] bind`)
  - Ports below 1024, or already used on the host, are refused:
    a flk.toml can't take over sshd
  - With several machines, the next takes over when one stops
- `[http_service]` stays private unless `[flk] http_port = N`

<!-- pause -->

New: **`[flk] internal_hosts = true`**

```
172.30.0.11 web.internal 3f9c1e.vm.web.internal
172.30.0.12 db.internal  a1fc6f.vm.db.internal
```

Plus `NAME.vm.APP.internal`. From `/etc/hosts`, kept current as machines
start and stop. No DNS server, no daemon, no root.

<!-- end_slide -->

Data
===

<!-- column_layout: [1, 1] -->

<!-- column: 0 -->

### Volumes

- Sparse ext4 files, one machine each
- `--path` on a bigger disk, `--from-dir`
- `extend`, `move` (reflink-aware)
- New: `--owner UID:GID`; by default the
  root takes the owner of the **mount
  point in the image**

<!-- column: 1 -->

### Backups

- Modes: `stop`, `live` (pre/post hooks
  typed into the console), `pause`
- Every backup is fsck'd; optional verify hook
- `restore --as NEW`: test a restore, no downtime
- Copies to another disk or host (rsync)
- Space checked before it starts

<!-- reset_layout -->

<!-- pause -->

```bash
flk files ls world:/world   # no mount, no root
flk files cp ops.json world:/ops.json --owner 1000
```

<!-- end_slide -->

Built for agents too
===

- `flk context [--json]`: host health, the app, machines, ports, **next steps**
- `flk help --all [--json]`: the full reference, generated from one command table
- Listing commands take `--json`; JSON carries `"schema": 1` (additive only)
- **Nothing hangs** without a terminal: `logs` prints and exits,
  `apps destroy` needs `--yes`, `console` refuses to attach
- Unknown options and extra arguments are errors, never ignored
- Commands that change something end with `Next:`, errors too

<!-- pause -->

`AGENTS.md` is twenty lines: ask the CLI instead of guessing.

<!-- end_slide -->

lazyflk
===

A terminal UI for flk hosts: **github.com/dayne/d.lazyflk**

- Tree of apps and machines with live CPU and memory, ports, health
- Logs with follow and search, console attach, actions that show their
  `flk` command first, a palette of every flk command
- Host tabs: health, services, ports, disk, images

<!-- pause -->

It talks to flk **only through its CLI and JSON**: that's its whole API.
Gaps go into flk's `TODO.md` ("For lazyflk", G1–G15, all done), so every
agent and script gets them too.

<!-- end_slide -->

Under the hood
===

| Path                  | What                                          |
|-----------------------|-----------------------------------------------|
| `lib/flk/commands.rb` | the command table: parsing, help, completion  |
| `lib/flk/cli/*.rb`    | handlers, one file per command group          |
| `lib/flk/*.rb`        | vm, image, ports, backup, volfs, events, hosts |
| `agent/`              | flk-agent (Go): exec, ssh, hosts, static init |
| `libexec/`            | rootfs builder, assets, log pipe, port helper |
| `share/`              | guide, help topics, `init.sh`                 |
| `tests/`              | 167 tests in 19 files; `--fast`: no VMs, no root |

<!-- pause -->

About 6,000 lines of Ruby and 700 of Go. Changes land in a git worktree
and only reach `main` after the full suite passes, because the game
servers run from that checkout.

<!-- end_slide -->

Where it stands
===

| Milestone                              | Status          |
|----------------------------------------|-----------------|
| M1 Backups you can trust               | done 2026-10-13 |
| M2 Volume files without root           | done 2026-10-13 |
| M3 Talk to running machines            | done 2026-10-13 |
| First-app fixes (opencode.flk)         | done 2026-10-14 |
| M4 Networking between apps             | done 2026-10-14 |
| M5 More than one host                  | design first    |

<!-- pause -->

Decided: `/etc/hosts` over a DNS server, no `127.0.0.1` forwarding
(`route_localnet`), keep tmux's Ctrl-b, `flk exec` stays root.

<!-- end_slide -->

What's next
===

- **M5, more than one host:** extra addresses, keepalived hooks,
  `volumes sync --to HOST`, fencing so an app never runs twice
- **Snapshots:** machine suspend/resume (memory-sized files),
  instant volume snapshots (wants XFS)
- **Portability:** firewalld, pacman and ufw paths on real hosts
- **CI** for the fast tests

<!-- end_slide -->

Live
===

Run with `presenterm -x` to execute:

```bash +exec
flk context --all | head -n 20
```

<!-- end_slide -->

<!-- jump_to_middle -->

Thanks
===

`flk help` · `flk context` · `README.md` · `AGENTS.md`
