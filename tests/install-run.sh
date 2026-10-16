#!/usr/bin/env bash
# Shared install-test script for Ubuntu and Arch VMs.
# Executed inside a Firecracker VM by tests/cases/60-install-ubuntu.sh
# and tests/cases/61-install-arch.sh. The flk source tree is mounted at
# /flk-src via a volume.
#
# KVM, bridge, taps, port helper and boot service checks are expected to
# fail (no nested virt, no setup-host.sh). Everything else should pass.
set -uo pipefail
export PATH="$PATH:/usr/sbin:/sbin"  # mkfs.ext4 lives here on Debian/Ubuntu

FLK_SRC=/flk-src
PASS=0; FAIL=0

p()   { echo "  PASS: $*"; PASS=$((PASS + 1)); }
f()   { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }
hdr() { echo; echo "==> $*"; }

# Checks expected to fail in any VM (no nested virt / no setup-host.sh run).
EXPECTED_HOST_FAILS='kvm|/dev/kvm|/dev/net/tun|bridge|tap pool|port helper|boot service'

# ---------- detect distro -------------------------------------------------
. /etc/os-release 2>/dev/null || true
DISTRO="${ID:-unknown}"
echo "==> FLK INSTALL TEST: ${PRETTY_NAME:-$DISTRO}"

case "$DISTRO" in
  ubuntu|debian) PKG_MGR=apt ;;
  arch)          PKG_MGR=pacman ;;
  *)             echo "SKIP: unsupported distro '$DISTRO'"; exit 98 ;;
esac

# ---------- 1. sanity before install: should report missing packages ------
hdr "Step 1: sanity before install (expect package failures)"
$FLK_SRC/flk-sanity.sh --no-doctor --skip kvm,host,firewall 2>&1 | tee /tmp/sanity-pre.out || true
# Pass if sanity ran and correctly identified gaps (i.e., it found failures)
if grep -qE 'failed|Install missing' /tmp/sanity-pre.out; then
  p "sanity correctly reports what needs installing"
else
  f "sanity ran but gave no failures before install — unexpected"
fi

# ---------- 2. install packages -------------------------------------------
hdr "Step 2: install packages"
case "$PKG_MGR" in
  apt)
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq 2>&1 | tail -1
    apt-get install -y -qq ruby tmux e2fsprogs fakeroot podman iproute2 nftables curl sudo procps \
      2>&1 | tail -3
    ;;
  pacman)
    pacman -Sy --noconfirm --needed ruby tmux e2fsprogs fakeroot podman iproute2 nftables curl sudo procps-ng \
      2>&1 | tail -3
    # Arch's podman (crun) requires cgroup v2. Real Arch servers run systemd
    # which mounts cgroupv2 at boot; the Firecracker init doesn't.
    # Use runc (supports cgroup v1) instead of crun as the OCI runtime.
    pacman -S --noconfirm --needed runc 2>&1 | tail -2
    mkdir -p /etc/containers
    echo -e '[engine]\nruntime = "runc"' > /etc/containers/containers.conf
    echo "OCI runtime set to runc (cgroup v1 support)"
    ;;
esac
p "packages installed ($PKG_MGR)"

# ---------- 3. sanity after install: packages should all pass -------------
hdr "Step 3: sanity after install (packages only)"
$FLK_SRC/flk-sanity.sh --no-doctor --only packages 2>&1 | tee /tmp/sanity-pkgs.out || true
if grep -qF "0 failed" /tmp/sanity-pkgs.out && grep -qF "0 warnings" /tmp/sanity-pkgs.out; then
  p "all package checks pass after install"
else
  f "package checks still failing after install — see above"
  grep -E '^\s+[✘!]' /tmp/sanity-pkgs.out || true
  echo "--- podman info (for debugging):"
  podman info 2>&1 | head -20 || true
fi

# ---------- 4. flk setup --fix --------------------------------------------
hdr "Step 4: flk setup --fix"
$FLK_SRC/bin/flk setup --fix 2>&1 | tee /tmp/setup.out || true
# Doctor will fail on KVM/bridge (expected), but firecracker + kernel should download OK
if grep -qF "firecracker" /tmp/setup.out && grep -qF "guest kernel" /tmp/setup.out; then
  p "firecracker and guest kernel downloaded"
else
  f "flk setup did not download expected assets"
fi
if grep -qE 'Configured podman|flk-docker-io' /tmp/setup.out; then
  p "flk setup --fix applied podman registries fix"
else
  f "flk setup --fix did not apply registries fix"
fi
SYM_EXPECTED="$HOME/.local/bin/flk"
if grep -qF "Linked" /tmp/setup.out || [[ -L $SYM_EXPECTED ]]; then
  p "flk setup --fix: PATH symlink in place ($SYM_EXPECTED)"
else
  f "flk setup --fix did not create PATH symlink ($SYM_EXPECTED)"
fi

# ---------- 5. verify fix artifacts on disk --------------------------------
hdr "Step 5: verify fix artifacts"
REG="$HOME/.config/containers/registries.conf.d/50-flk-docker-io.conf"
if [[ -f $REG ]] && grep -q 'docker.io' "$REG"; then
  p "registries drop-in exists: $REG"
else
  f "registries drop-in missing or wrong: $REG"
fi

SYM="$HOME/.local/bin/flk"
if [[ -L $SYM ]] && [[ $(readlink "$SYM") == "$FLK_SRC/bin/flk" ]]; then
  p "PATH symlink: $SYM -> $FLK_SRC/bin/flk"
else
  f "PATH symlink wrong (got: $(ls -la "$SYM" 2>&1 || echo missing))"
fi

# ---------- 6. flk CLI works via PATH symlink ------------------------------
hdr "Step 6: flk on PATH"
if "$SYM" version >/dev/null 2>&1; then
  p "flk via PATH symlink: $("$SYM" version)"
else
  f "flk not runnable via PATH symlink"
fi

# ---------- 7. final sanity: only host-level items should fail -------------
hdr "Step 7: full sanity (only KVM/bridge/host items expected to fail)"
$FLK_SRC/flk-sanity.sh 2>&1 | tee /tmp/sanity-final.out || true
# Find any ✘ failures that aren't the expected host-level ones
unexpected=$(grep -E '^\s+✘' /tmp/sanity-final.out | grep -vE "$EXPECTED_HOST_FAILS" || true)
if [[ -n $unexpected ]]; then
  f "unexpected failures in final sanity:"
  echo "$unexpected" >&2
else
  p "final sanity: only expected host-level items fail (KVM/bridge/taps)"
fi

# ---------- summary -------------------------------------------------------
echo
echo "================================"
if ((FAIL == 0)); then
  echo "INSTALL TEST PASSED ($PASS checks, distro: $PRETTY_NAME)"
else
  echo "INSTALL TEST FAILED ($FAIL/$((PASS + FAIL)) checks failed, distro: $PRETTY_NAME)"
  exit 1
fi
