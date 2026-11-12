# Writing a Dockerfile for flk

flk builds your Dockerfile with podman (or docker), then turns the image
into an ext4 disk that boots in a Firecracker VM. Most Dockerfiles work
unchanged, but the guest is a small VM, not a container. The differences
are below.

**What a deploy does with it.** `podman build` (labelled `flk.app`,
`flk.release`), then the image is unpacked next to flk's release images
(not in /tmp; it needs about twice the image's size free there) into
`images/vN.ext4`, plus flk's `/flk` directory: its init, the agent for
`flk exec`, and your image's CMD, USER, WORKDIR and ENV. Each machine
boots a fresh copy of that disk, thrown away at the next deploy: anything
that must last goes on a volume. A failed build prints what the build
said and keeps its output in `APP/builds/` (`Build log: FILE`;
`flk releases log` prints it).

**Try it without deploying.** `flk build` makes the same image and disk,
with no app registered and no machines, and says what flk will do with
them: shell init or the static one, the command, the user the app runs as
and how init switches to it, whether `flk exec` will work, and what each
`[[mounts]]`
destination holds in the image. `--json` for scripts. Then its warnings,
each with its fix: a USER the image doesn't have or can't switch to, no
CMD, no agent (no `flk exec`), a mount over files the image has there (the
volume hides them), over a file, or on a directory owned by another user,
and a volume the app's user can't write to. A deploy prints the same ones
and keeps them in the release (`flk releases --json`, `flk config show`);
none stops it.

**Name images in full.** `FROM docker.io/library/ubuntu:24.04`, not
`FROM ubuntu:24.04`: podman on Ubuntu has no search registries, and short
names fail ("short-name did not resolve").

**The app is PID 1's only child.** flk's init mounts /proc, /sys, /dev,
the volumes, writes the hostname, `/etc/hosts` and `/etc/resolv.conf`,
then runs ENTRYPOINT + CMD as the one app. When it exits, the VM powers
off and the restart policy decides what's next. There's no systemd or
cron: run daemons in the foreground (as the app, or started by a wrapper
script). Don't let the image manage networking. An image without
`/bin/sh` (scratch, distroless) boots with flk's static init, which comes
with the agent (building it needs Go on the host: `flk doctor`).

**Inside the machine.** `[env]`, secrets, and: `FLY_APP_NAME`,
`FLK_APP_NAME`, `FLY_MACHINE_ID`, `FLK_MACHINE_ID`, `FLY_PRIVATE_IP`,
`FLK_IP`, `FLK_HOSTNAME` (the machine's name), `FLY_REGION=local`,
`FLK_RELEASE` (`vN`), `FLK_PREFIX`, `FLK_GATEWAY`, `FLK_DNS`, `FLK_STDIN`.
The app's stdin is the serial console (`flk console`), unless
`[flk] stdin = "null"`.

**USER.** flk switches to the image's USER with util-linux's `setpriv`
(Debian, Ubuntu and Fedora images have it), else with flk-agent (Alpine:
busybox's `setpriv` can't), else a `chroot` that takes `--userspec`.
Groups are cleared; the user and group come from the image's
`/etc/passwd` and `/etc/group`. Only with none of them (no agent: no Go
on the host) does the app run as root, with a warning in the boot log;
`flk build` says which applies.

**Volumes and their owner.** `[[mounts]]` puts a volume over a path,
hiding whatever the image had there: seed it at first start if the app
needs files in it. A new volume (`flk volumes create`, no `--owner`)
takes the owner of the mount point in the image the first time it's
used, or else the image's USER. Make the mount point in the image owned
by the app's user (`RUN install -d -o app -g app /data`) and both are
right. Fix one that isn't, with the machine stopped:
`flk files chown UID:GID VOL:/`.

**Stopping cleanly.** `flk machine stop` sends the app SIGTERM, then kills
the VM after `kill_timeout` (default 10s, at most 300s). A server that
saves on a console command or another signal needs a small wrapper that
turns SIGTERM into that, and a `kill_timeout` longer than the save. A
wrapper that also restarts the server should go with
`[[restart]] retries = 1`, so flk's restarts don't multiply its own.

**Pin what you download.** Put versions in `[build] args`
(`args = { VERSION = "1.2.3" }`, read with `ARG VERSION`) and check
downloads with sha256. Old releases come back only from flk's kept images
(`[flk] keep_releases`, `flk releases rollback`).

**Readiness.** `[checks.NAME]` decide when a deploy is done: `tcp` and
`http` on a port, or `log`, a regex for a console line (`^` and `$` match
line by line). A udp-only server needs a log check: flk can't tell when a
udp port is ready.

Every flk.toml key, annotated: `{{SRC}}/examples/reference/flk.toml`.
