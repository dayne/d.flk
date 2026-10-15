# flk: the fly.io workflow for local Firecracker microVMs

`flk` gives you `fly launch` / `fly deploy` / `fly machine` / `fly volumes` /
`fly secrets` on your own Linux box, backed by Firecracker microVMs. It reads
your existing `fly.toml` unchanged, so the same app directory can deploy to
Fly or to your laptop.

Written in Ruby (stdlib only, no gems) for the logic and bash for system
plumbing, plus a small Go guest agent (`agent/`) for `flk exec`,
`flk ssh console`, and booting images that have no `/bin/sh`. flk builds
the agent itself when Go is installed; without Go, everything else works.

## Concept map

| fly.io                         | flk                                                        |
|--------------------------------|------------------------------------------------------------|
| `fly.toml`                     | `flk.toml`, or `fly.toml` as-is                            |
| Fly builder / registry         | local `podman` (or `docker`) build, then ext4 rootfs       |
| Machine (Firecracker VM)       | Firecracker VM in a detached session on flk's own tmux server (`tmux -L flk`) |
| Fly init (PID 1)               | `/flk/init`: a POSIX sh script, or the static flk-agent for images without a shell |
| 6PN private network            | bridge `flkbr0`, 172.30.0.0/24, NAT out                    |
| Volume                         | sparse ext4 file attached as a virtio-blk drive            |
| Secrets                        | `secrets.json` (0600), delivered on a per-boot config drive|
| `fly proxy`                    | `flk proxy` (pure Ruby TCP forwarder)                      |
| `fly ssh console`              | `flk ssh console` / `flk exec` (vsock agent); `flk console` attaches the serial console |
| `APP.internal` DNS             | `APP.internal` in `/etc/hosts`, opt-in (`[flk] internal_hosts`) |
| `FLY_APP_NAME`, `FLY_MACHINE_ID`, `FLY_PRIVATE_IP`, `FLY_REGION=local` | set in every VM, plus `FLK_*` equivalents |

## Quick start

```bash
# 1. Host deps (Ubuntu / CachyOS-Arch)
sudo apt install -y ruby tmux e2fsprogs fakeroot podman iproute2 nftables curl
sudo pacman -S --needed ruby tmux e2fsprogs fakeroot podman iproute2 nftables curl
# Optional, for flk exec, flk ssh console and images without /bin/sh: Go (golang-go / go), or set FLK_GO

# 2. One-time root setup: kvm group, bridge, user-owned tap pool, NAT, port forwarding
sudo ./setup-host.sh
sudo ./setup-host.sh --install-service   # recommended: at boot, recreate networking and resume machines

# 3. Firecracker + guest kernel into ~/.local/share/flk (no root)
ln -s "$PWD/bin/flk" ~/.local/bin/flk
flk setup          # runs `flk doctor` at the end

# Optional: let podman resolve short image names like `FROM ruby:3.3`.
# Without this only fully qualified names (docker.io/library/ruby:3.3) work
# on Ubuntu/Debian podman. `flk doctor` warns when it's missing, and a deploy
# that hits it prints this fix. A drop-in adds to the system config; a
# user-level registries.conf would replace it.
mkdir -p ~/.config/containers/registries.conf.d
echo 'unqualified-search-registries = ["docker.io"]' > ~/.config/containers/registries.conf.d/50-flk-docker-io.conf

# 4. Deploy the example
cd examples/hello
flk launch --no-deploy
flk volumes create data --size 1
flk secrets set API_TOKEN=s3cr3t --stage
flk deploy
curl http://172.30.0.10:8080/
```

Day to day, nothing needs sudo after step 2.

Not sure what's missing? `./flk-sanity.sh` checks the host (hardware, packages,
groups, firewalls, then `flk doctor`) and prints the next thing to fix. Run it
again after each fix. `tests/run.sh` checks flk itself end to end.

## Commands

```
flk context [--all]           # what flk sees now: host, app(s), machines, ports, next steps
flk help [COMMAND|TOPIC]      # one command, or a guide: cheatsheet install first-app operate troubleshoot uninstall
flk help --all [--json]       # full reference: concepts, config, every command, the guides

flk launch | deploy | status | releases [rollback [vN]] | config show
flk start | stop | restart     # every machine of the app
flk machine list|start|stop|restart|destroy|stats|status|config ID...
flk scale count N
flk logs [-i ID] [-n N] [-f] | events [-f]
flk console [ID] [--send TEXT --wait-log REGEX]
flk exec [-i ID] CMD... | ssh console [ID] [-C CMD]
flk proxy 8080[:80] [ID] | ports [list|sync]
flk secrets list|set|unset|import
flk volumes list|create [--owner UID:GID]|import|destroy|extend|move
flk volumes backup|backups|verify|restore|copy
flk files ls|cat|cp|rm|mkdir|chown VOL:PATH        # no mount, no root
flk apps list|destroy|prune | disk | images
flk resume | stop-all | doctor | setup | completion bash | version
```

`-a APP` works anywhere, as with fly. Machine IDs accept prefixes or names.
Listing commands take `--json`. Unknown options and extra arguments are errors.
`flk help COMMAND` has every option.

A terminal UI, [lazyflk](https://github.com/dayne/d.lazyflk), runs on top of flk's CLI.

Help is generated from one command table (`lib/flk/commands.rb`); the
long-form reference is `share/guide.md` and the guides are `share/help/*.md`.
Hints and errors name the fix, with absolute paths for the root-side tools. AI agents: see [AGENTS.md](AGENTS.md).
An overview talk: [docs/flk-slides.md](docs/flk-slides.md) (`presenterm docs/flk-slides.md`).

## Config: the fly.toml subset

flk reads `flk.toml`, or a `fly.toml` unchanged: `app`, `[build]`, `[env]`,
`[[mounts]]`, `[http_service]`, `[[services]]` with their ports and checks,
`[checks]`, `[[restart]]`, `[[vm]]`, `kill_timeout` and `[experimental]`.
flk's own keys go under `[flk]` (host ports, bind addresses, releases kept,
kernel args) and `[flk.backup]` (how volume backups quiesce the app). Fly
keys flk doesn't use (regions, concurrency, statics) are ignored, and a key
nobody knows gets a "did you mean" warning.

- **Every key, annotated:** [examples/reference/flk.toml](examples/reference/flk.toml).
- **The rules** (defaults, limits, what's refused): the Config section of
  `flk help --all` ([share/guide.md](share/guide.md)).
- **Working apps:** [examples/hello](examples/hello) and
  [examples/minecraft](examples/minecraft).
- `flk config show` prints what flk understood, with warnings.

Host ports: `[[services.ports]]` are forwarded from every host address (or
`[flk] bind`) to the machine. `[http_service]` is *not* forwarded unless
you set `[flk] http_port`, since on Fly it means public 80/443. Ports below
1024 and ports a host process already listens on are refused, so a
flk.toml can't take over sshd. `flk ports` shows blocked ports and why.

## How a deploy works

1. `podman build` (or pull `[build] image`), tagged `flk.local/APP:vN`.
2. `libexec/flk-build-rootfs` exports the container and injects `/flk/{init,cmd,image.env,workdir,user}`. It then runs `mkfs.ext4 -d` under `fakeroot`, so file ownership and setuid bits are correct without root.
3. Each machine is rolled one at a time: stop, copy in a fresh rootfs (reflink when the filesystem supports it), and rebuild the config drive.
4. Firecracker starts in tmux and waits on its API socket. flk attaches the log pipe, configures the VM over the API, then sends `InstanceStart`.
5. `/flk/init` mounts filesystems, applies network, env, and secrets, mounts volumes, drops to the image's `USER`, and runs the app. When the app exits, the VM powers off, as on Fly.

As on Fly, the rootfs is ephemeral per release; persistent data goes on volumes.
Each volume attaches to exactly one machine, and redeploys keep the same pairing.

Stopping sends Ctrl-Alt-Del. The guest init turns that into SIGTERM for the app,
then powers off. flk falls back to TERM and then KILL on the firecracker process after 10s.

## State layout

```
~/.local/share/flk/
  bin/firecracker  kernel/vmlinux
  apps/APP/
    app.json  secrets.json  volumes.json
    images/vN.ext4                  # last 2 releases kept
    volumes/vol_xxx.ext4
    machines/ID/
      machine.json  vm.json  rootfs.ext4  config.ext4
      console.log  firecracker.log  fc.sock  pid
```

## Verify on first real run

Confirmed on real hardware (Ubuntu 26.04, Firecracker v1.17.0, CI kernel 6.18.51), with `tests/run.sh` passing:
kernel `ip=` autoconfig, `--log-path`, graceful stop via Ctrl-Alt-Del, volumes, secrets, scaling and NAT egress.
Still worth checking on a new host:

- **Kernel `ip=` autoconfig.** It depends on `CONFIG_IP_PNP` in the guest kernel. `flk setup` saves the kernel's config as `kernel/vmlinux.config` and warns if it's missing. Without it, init falls back to `ip` from the image (Alpine/busybox has it; debian-slim does not).
- **Firecracker CI kernel location.** Since 2026 CI kernels are in dated `firecracker-ci/YYYYMMDD-*` dirs rather than `firecracker-ci/vX.Y`. `flk-fetch-assets` tries both. Override with `FLK_KERNEL_URL=...` if the layout changes again.
- **Podman short image names.** `FROM ruby:3.3` only resolves if podman has search registries configured. `flk doctor` (and so `flk context` and `flk-sanity.sh`) warns when it doesn't, and a deploy that fails on it prints the fix. Fully qualified names (`docker.io/library/ruby:3.3`) always work.
- **Host firewalls.** A FORWARD drop from another firewall overrides flk's own nft accept rules and blackholes the bridge. `setup-host.sh` handles the common cases: `DOCKER-USER` accept rules for Docker, `ufw route allow` rules when ufw is active, and the trusted zone for firewalld. The ufw and firewalld paths are untested on real hosts. `flk-sanity.sh` checks for all three.

## Known limits

- **Zombie reaping in images with a shell is minimal.** Images without
  `/bin/sh` (scratch, distroless) boot with flk-agent as PID 1, which reaps
  every orphan; images with a shell use the shell init. Apps that spawn and
  orphan many processes should run under `tini` there.
- **`flk exec`, `flk ssh console` and shell-less images need Go on the
  host** to build the guest agent (see above). `flk console` is the serial console: app output,
  and your typing goes to the app's stdin (`[flk] stdin = "null"` for
  `/dev/null`).
- **`.internal` names are opt-in and come from `/etc/hosts`**, not DNS:
  `[flk] internal_hosts = true` gives `APP.internal` and
  `ID.vm.APP.internal` (no SRV/TXT records). Without it, use the
  172.30.0.x IPs (`flk status`).
- **x86_64 is the tested path.** On aarch64, Ctrl-Alt-Del isn't supported, so stop falls back to SIGTERM after 10s.

## What's next

The order of work is in [PLAN.md](PLAN.md); known rough edges and bigger
features (machine snapshots, volume snapshots, more than one host) are in
[TODO.md](TODO.md).
