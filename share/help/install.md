# Installing flk on a host

flk lives in `{{SRC}}`. Each step can be re-run safely; `./flk-sanity.sh`
says which step you're at.

Get the code first if you haven't already:

    git clone https://github.com/dayne/d.flk

> **Note:** Steps that use `sudo` must be run directly in a terminal.
> `sudo` requires a TTY to prompt for your password and will fail if
> invoked from a script runner or pipe that has no terminal.

1. **Check the host.** `{{SRC}}/flk-sanity.sh` checks hardware (KVM),
   packages, groups and firewalls, and prints the next thing to fix,
   including the exact package install command for your distro.
   When multiple steps are needed it prints a numbered list.

2. **Root setup, once.**

       sudo {{SRC}}/setup-host.sh                    # kvm group, bridge, taps, NAT, port helper
       sudo {{SRC}}/setup-host.sh --install-service  # at boot: recreate network + resume machines

   **On a server, run both commands.** Without `--install-service` a reboot
   leaves all machines down — `flk doctor` will warn when the service is
   missing.

   If the first command added you to the `kvm` group, log out and back in
   (or: `newgrp kvm`). Options are environment variables: `FLK_TAPS`
   (machines at once, default 16), `FLK_SUBNET` (default 172.30.0),
   `FLK_MIN_PORT` (lowest forwardable host port, default 1024).

3. **flk on your PATH, downloads, and quick fixes (no root).**

       {{SRC}}/bin/flk setup --fix

   `flk setup` downloads firecracker and the guest kernel into `{{ROOT}}`,
   then runs `flk doctor`. It stops first if a package is missing (step 1
   names them). The `--fix` flag also applies two one-offs where needed
   (no root, safe to re-run on any distro):

   - **Podman short image names** — lets `FROM ruby:3.3` resolve without
     the full `docker.io/library/ruby:3.3` prefix.
   - **`~/.local/bin/flk` symlink** — so `flk` is on your PATH. Ubuntu's
     `~/.profile` adds `~/.local/bin` at login once it exists, so log in
     again; elsewhere (Arch's default bash) add
     `export PATH="$HOME/.local/bin:$PATH"` to your shell rc. Setup says
     when this shell can't find it yet.

   Without `--fix`, `flk setup` lists them and asks before applying them
   when run in a terminal; otherwise it suggests `flk setup --fix`.

4. **Optional: Go, for `flk exec`, `flk ssh console`, and images without
   `/bin/sh`.** flk builds a small guest agent from `{{SRC}}/agent` with
   Go (on PATH, in `~/.local/go`, or `FLK_GO`) and puts it in each
   release. Without Go, everything else works; `flk doctor` says when
   it's missing. Install Go, then run `flk setup` again.

5. **Optional: shell completion** (commands, options, app names, machine IDs).

       echo 'source <(flk completion bash)' >> ~/.bashrc

   Or, where the bash-completion package is loaded, drop it in its folder:
   `flk completion bash > ~/.local/share/bash-completion/completions/flk`.

6. **Check.** `flk doctor` should say "Ready to fly, locally." (any `!`
   lines under "Optional" after it are features you can add later).
   `{{SRC}}/tests/run.sh` runs the end-to-end tests (a few minutes).

Next: flk help first-app
