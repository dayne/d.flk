# Installing flk on a host

flk lives in `{{SRC}}`. Each step can be re-run safely; `./flk-sanity.sh`
says which step you're at.

1. **Check the host.** `{{SRC}}/flk-sanity.sh` checks hardware (KVM),
   packages, groups and firewalls, and prints the next thing to fix,
   including the exact package install command for your distro.

2. **Root setup, once.**

       sudo {{SRC}}/setup-host.sh                    # kvm group, bridge, taps, NAT, port helper
       sudo {{SRC}}/setup-host.sh --install-service  # at boot: network, then flk resume

   If it added you to the `kvm` group, log out and back in (or `newgrp kvm`).
   Options are environment variables: `FLK_TAPS` (machines at once, default
   16), `FLK_SUBNET` (default 172.30.0), `FLK_MIN_PORT` (lowest forwardable
   host port, default 1024).

3. **flk on your PATH, and its downloads (no root).**

       ln -s {{SRC}}/bin/flk ~/.local/bin/flk
       flk setup        # firecracker + guest kernel into {{ROOT}}, then flk doctor

4. **Podman short image names** (Ubuntu/Debian): if `flk doctor` warns that
   podman can't resolve `FROM ruby:3.3`, run the one-liner it shows. It adds
   a user-level drop-in, no root.

5. **Optional: shell completion.**

       mkdir -p ~/.local/share/bash-completion/completions
       flk completion bash > ~/.local/share/bash-completion/completions/flk

6. **Check.** `flk doctor` should end with "Ready to fly, locally."
   `{{SRC}}/tests/run.sh` runs the end-to-end tests (a few minutes).

Next: flk help first-app
