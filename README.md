# flk: the fly.io workflow for local Firecracker microVMs

`flk` gives you `fly launch` / `fly deploy` / `fly machine` / `fly volumes` /
`fly secrets` on your own Linux box, backed by Firecracker microVMs. It reads
your existing `fly.toml` unchanged, so the same app directory can deploy to
Fly or to your laptop.

Written in Ruby (stdlib only, no gems) for the logic, and bash for system plumbing.

## Concept map

| fly.io                         | flk                                                        |
|--------------------------------|------------------------------------------------------------|
| `fly.toml`                     | `flk.toml`, or `fly.toml` as-is                            |
| Fly builder / registry         | local `podman` (or `docker`) build, then ext4 rootfs       |
| Machine (Firecracker VM)       | Firecracker VM in a detached session on flk's own tmux server (`tmux -L flk`) |
| Fly init (PID 1)               | `/flk/init`, a POSIX sh script injected into the rootfs    |
| 6PN private network            | bridge `flkbr0`, 172.30.0.0/24, NAT out                    |
| Volume                         | sparse ext4 file attached as a virtio-blk drive            |
| Secrets                        | `secrets.json` (0600), delivered on a per-boot config drive|
| `fly proxy`                    | `flk proxy` (pure Ruby TCP forwarder)                      |
| `fly ssh console`              | `flk console` (serial console attach)                      |
| `FLY_APP_NAME`, `FLY_MACHINE_ID`, `FLY_PRIVATE_IP`, `FLY_REGION=local` | set in every VM, plus `FLK_*` equivalents |

## Quick start

```bash
# 1. Host deps (Ubuntu / CachyOS-Arch)
sudo apt install -y ruby tmux e2fsprogs fakeroot podman iproute2 nftables curl
sudo pacman -S --needed ruby tmux e2fsprogs fakeroot podman iproute2 nftables curl

# 2. One-time root setup: kvm group, bridge, user-owned tap pool, NAT, port forwarding
sudo ./setup-host.sh
sudo ./setup-host.sh --install-service   # optional: recreate at boot

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
flk context                  # what flk sees now: host, current app, machines, ports, next steps
flk help [COMMAND]           # short help, or one command (same as: flk COMMAND --help)
flk help --all [--json]      # full reference: concepts, every command, config, workflows
flk launch | deploy | status | releases
flk machine list|start|stop|restart|destroy|status|config ID...
flk scale count N
flk logs [-i ID] [-n N] [-f]                # follows only in a terminal
flk console [ID]                            # Ctrl-b d to detach (Ctrl-b Ctrl-b d inside tmux)
flk proxy 8080[:80] [ID] [--bind 0.0.0.0]
flk secrets list | set K=V (V='-' reads stdin) | unset K | import  [--stage]
flk volumes list | create NAME [-s GB] | destroy ID|NAME
flk apps list | destroy NAME [--yes]
flk ports [list|sync]                       # host ports forwarded to machines
flk config show
flk doctor | setup
```

`-a APP` works anywhere, as with fly. Machine IDs accept prefixes or names.
Listing commands take `--json`. Unknown options and extra arguments are errors.

Help is generated from one command table (`lib/flk/commands.rb`), and the
long-form reference text lives in `share/guide.md`. AI agents: see [AGENTS.md](AGENTS.md).

## Supported fly.toml subset

- `app`
- `[build]`: `dockerfile`, `image`, `args`
- `[env]`
- `[[mounts]]`: `source`, `destination`
- `[http_service] internal_port` (or the first `[[services]]` entry). This drives the post-boot "listening" check.
- `[[services]]` with `protocol` (`tcp`/`udp`) and `[[services.ports]] port`: forwarded from every host address (your LAN IP included) to the machine's `internal_port`. With several machines, the first running one owns the port and the next takes over when it stops. `[http_service]` is *not* forwarded, since on Fly it means public 80/443. Host ports below 1024 are refused (to allow one: `sudo FLK_MIN_PORT=80 ./setup-host.sh`), and so is any port a host process already listens on outside loopback, so a flk.toml can't take over sshd or a database. `flk ports` shows blocked ports and why. If a machine exits on its own, the next `flk status`, `flk ports` or `flk machine list` gives its port to the next machine or drops it.
- `kill_timeout`: seconds (`30`, `"30s"`, `"2m"`) between asking the app to stop and killing the VM. Default 10, at most 300 (5 minutes). Raise it for apps that save on shutdown, like game servers.
- `[[vm]]`: `cpus`, `memory` (`'1gb'`/`'512mb'`), `memory_mb`, and `size` presets (`shared-cpu-Nx`, `performance-Nx`)
- `[experimental]`: `cmd`, `entrypoint`

flk-only keys go under `[flk]`:

- `kernel_args`: appended to the boot cmdline
- `rootfs_extra_mb`: free space added to the rootfs (default 512)

Everything else (regions, concurrency, checks, statics) is ignored.

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

- **Images need `/bin/sh`**, because init and the cmd wrapper are shell scripts. Distroless/scratch images won't boot yet.
- **Zombie reaping is minimal.** Apps that spawn and orphan many processes should run under `tini` inside the image.
- **`flk console` is the serial console**, not a separate shell. You see app output and can type to its stdin.
- **No `.internal` DNS between machines yet.** Use the 172.30.0.x IPs (`flk status`).
- **x86_64 is the tested path.** On aarch64, Ctrl-Alt-Del isn't supported, so stop falls back to SIGTERM after 10s.

## Natural next steps

Known rough edges and follow-ups are tracked in [TODO.md](TODO.md).


- **vsock exec agent.** A tiny guest agent on vsock would give a real `flk ssh console` and `flk ssh console -C "cmd"`, the way Fly's hallpass does.
- **`APP.internal` DNS.** A small dnsmasq on the bridge, fed from machine records.
- **Snapshots.** Firecracker snapshot/restore would give `flk machine suspend` and sub-second resume.
- **Rolling health gate.** Abort the deploy if a machine never starts listening, rather than just warning.
- **Static Go/Rust init.** Removing the `/bin/sh` requirement would let distroless images boot.
