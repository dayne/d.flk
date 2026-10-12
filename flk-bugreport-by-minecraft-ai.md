# flk fixes and feature requests (from the minecraft.flk project)

Each entry below is a self-contained prompt for the AI that develops flk
(`~/flk`). They were found while running a real Fabric Minecraft server in
flk (app `minecraft-flk`, `~/minecraft.flk`). Paste one entry at a time.
Each entry says whether the problem was verified or only suspected.

---

## 1. Bug: VMs have no `/dev/fd`, so bash process substitution fails (verified)

**Prompt:**

> In flk, the guest init (`share/init.sh`) mounts a fresh devtmpfs on `/dev`
> (line 9: `mount -t devtmpfs devtmpfs /dev`). devtmpfs only contains device
> nodes. It doesn't have the symlinks that udev or systemd normally create:
> `/dev/fd -> /proc/self/fd`, `/dev/stdin -> /proc/self/fd/0`,
> `/dev/stdout -> /proc/self/fd/1` and `/dev/stderr -> /proc/self/fd/2`.
> Docker and podman create these in containers, so images that work there
> break in flk.
>
> **Symptom:** any app using bash process substitution fails inside a flk VM.
> `cmd > >(other)` and `diff <(a) <(b)` both rely on `/dev/fd/N`. Seen in a
> real deploy, where a wrapper script running
> `java ... > >(watch_output) 2>&1 &` failed immediately with:
>
>     /usr/local/bin/mc-run: line 108: /dev/fd/63: No such file or directory
>
> The same script works under `podman run`. Anything writing to `/dev/stdout`
> or `/dev/stderr` by path (common in nginx configs and logging setups) fails
> the same way.
>
> **Fix:** in `share/init.sh`, right after `/proc` and `/dev` are mounted, add:
>
>     ln -sf /proc/self/fd   /dev/fd
>     ln -sf /proc/self/fd/0 /dev/stdin
>     ln -sf /proc/self/fd/1 /dev/stdout
>     ln -sf /proc/self/fd/2 /dev/stderr
>
> Consider also `/dev/core -> /proc/kcore` and `/dev/ptmx -> pts/ptmx`, to
> match what container runtimes provide. `/dev/pts` is already mounted.
>
> **Test:** add a test that deploys an image whose CMD is
> `bash -c 'cat <(echo ok); echo hi > /dev/stdout; ls -l /dev/fd/'` and checks
> `flk logs` shows `ok` and `hi` with no "No such file or directory".
> Document the fix in `share/guide.md` if there's a gotchas section.

---

## 2. Bug (suspected): the app's stdin is `/dev/null`, so `flk console` can't type to it

**Prompt:**

> Please verify this, then fix it if it's real. flk's docs say `flk console`
> is "the serial console, not a shell: you see app output and type to its
> stdin". But `share/init.sh` starts the app with `start_app &` (line 82). In a
> non-interactive POSIX sh without job control, an asynchronous command's
> stdin is redirected from `/dev/null` unless it's explicitly redirected
> (POSIX "Asynchronous Lists"; dash does this). So the app probably never sees
> what's typed on the console.
>
> **How to check:** deploy an image with CMD
> `sh -c 'ls -l /proc/self/fd/0; while read l; do echo "got: $l"; done'`,
> attach with `flk console`, and type a line. If fd 0 is `/dev/null` and
> nothing echoes, the bug is real.
>
> **Fix:** give the app the console explicitly, e.g. `start_app </dev/console &`
> (or `/dev/ttyS0`), keeping stdout/stderr where they are now. Make sure a
> SIGINT from Ctrl-C on the console still goes to init's trap the way it does
> today. Consider whether the app should get a controlling tty (`setsid -c`).
>
> **Why it matters:** Minecraft and similar servers take admin commands on
> stdin (`stop`, `say`, `op`). The minecraft.flk project currently works
> around it with its own FIFO.

---

## 3. Feature: volumes backed by a file outside flk's state dir, plus import from a directory

**Prompt:**

> flk volumes are always created as
> `~/.local/share/flk/apps/APP/volumes/ID.ext4` (`volumes_create` in
> `lib/flk/cli.rb`). For real data this is often the wrong disk. In
> minecraft.flk, the root filesystem had 11G free but the world was 21G on a
> separate LVM volume. The workaround was to build the image by hand with
> `mkfs.ext4 -d /data/minecraft/primary-minecraft world.ext4`, create a
> placeholder volume, and hand-edit `path` (and `size_gb`) in `volumes.json`.
>
> **Requested:**
> - `flk volumes create NAME --size GB --path FILE`: create the sparse image at
>   FILE (refuse if it exists).
> - `flk volumes import NAME --path FILE`: register an existing ext4 image
>   (check with `e2fsck -n`/`blkid` that it's ext4; take the size from the file).
> - `flk volumes create NAME --size GB --from-dir DIR`: populate the volume
>   with `mkfs.ext4 -d DIR`. `Util.mkfs_ext4` already takes `from_dir:`; it's
>   just not exposed. Warn that ownership is copied as-is, and refuse if DIR is
>   bigger than the volume.
> - Show the path in `flk volumes list` (at least with `--json`).
>
> **Safety, important:** `volumes_destroy` (and `apps destroy`) run
> `FileUtils.rm_f(v["path"])`. For a volume flk didn't create in its own state
> dir, deleting user data silently is dangerous. Record `"external": true`
> for `--path`/`import` volumes. On destroy, either keep the file and say
> "unregistered; file kept at PATH", or require an explicit `--delete-data`.
> `apps destroy --yes` should list external volumes it will leave alone.

---

## 4. Feature/docs: host ports aren't reachable via 127.0.0.1 on the host

**Prompt:**

> `[[services.ports]]` forwarding is done with nft DNAT, and the rules
> deliberately skip 127.0.0.0/8 (`lib/flk/ports.rb`, `libexec/flk-ports`). So
> on the host, `nc 127.0.0.1 25565` gets "connection refused", while the LAN IP
> and the machine IP (`172.30.0.x`) both work. This surprised a user testing a
> freshly deployed Minecraft server ("is it even up?").
>
> **Requested, at least the first:**
> 1. Docs: say plainly in `share/guide.md` (Host ports section) and in
>    `flk ports` output that forwarded ports don't answer on 127.0.0.1 from the
>    host, and suggest the machine IP or LAN IP instead.
> 2. Optional: an opt-in way to reach a port on loopback, e.g. a per-port flag,
>    or have `flk context` print the LAN address for each forwarded port.
>    `flk proxy` already covers ad-hoc TCP, but not UDP.
