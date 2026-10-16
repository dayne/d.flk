#!/usr/bin/env bash
# Shared install-test script for Ubuntu, Arch and Fedora VMs.
# Executed inside a Firecracker VM by tests/cases/60-install-ubuntu.sh,
# 61-install-arch.sh and 62-install-fedora.sh. The flk source tree is
# mounted at /flk-src via a volume.
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
EXPECTED_HOST_FAILS='no vmx/svm|kvm|/dev/kvm|/dev/net/tun|bridge|tap pool|port helper|boot service'

# ---------- detect distro -------------------------------------------------
. /etc/os-release 2>/dev/null || true
DISTRO="${ID:-unknown}"
echo "==> FLK INSTALL TEST: ${PRETTY_NAME:-$DISTRO}"

case "$DISTRO" in
  ubuntu|debian) PKG_MGR=apt ;;
  arch)          PKG_MGR=pacman ;;
  fedora)        PKG_MGR=dnf ;;
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

# ---------- 2. install packages: the command sanity suggested --------------
# Running sanity's own command is what tests its PKG table (per distro).
hdr "Step 2: install packages"
cmd=$(grep -A1 '^Install missing packages:' /tmp/sanity-pre.out | tail -n +2 | sed 's/^ *//; s/^sudo //')
case "$PKG_MGR" in
  apt)    export DEBIAN_FRONTEND=noninteractive; apt-get update -qq 2>&1 | tail -1 ;;
  pacman) pacman -Sy --noconfirm 2>&1 | tail -1; cmd=${cmd/pacman -S /pacman -S --noconfirm } ;;
esac
if [[ $cmd != "$PKG_MGR "* ]]; then
  f "sanity suggested no $PKG_MGR install command (got: '${cmd}')"
else
  echo "+ $cmd"
  if $cmd 2>&1 | tail -3; [[ ${PIPESTATUS[0]} -eq 0 ]]; then
    p "sanity's install command worked ($cmd)"
  else
    f "sanity's install command failed: $cmd"
  fi
fi
# podman needs cgroup v2; systemd mounts it at boot on a real host, but the
# Firecracker init doesn't.
grep -q cgroup2 /proc/mounts 2>/dev/null || mount -t cgroup2 none /sys/fs/cgroup 2>/dev/null || true

# ---------- 3. sanity after install: packages should all pass -------------
hdr "Step 3: sanity after install (packages only)"
$FLK_SRC/flk-sanity.sh --no-doctor --only packages 2>&1 | tee /tmp/sanity-pkgs.out || true
if grep -qF "0 failed" /tmp/sanity-pkgs.out && grep -qF "0 warnings" /tmp/sanity-pkgs.out; then
  p "all package checks pass after install"
else
  f "package checks still failing after install — see above"
  grep -E '^\s+[✘!]' /tmp/sanity-pkgs.out || true
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
# Fedora's podman already searches docker.io: nothing to fix there.
search=$(podman info --format '{{json .Registries.search}}' 2>/dev/null)
REG="$HOME/.config/containers/registries.conf.d/50-flk-docker-io.conf"
if grep -qE 'Configured podman|flk-docker-io' /tmp/setup.out; then
  p "flk setup --fix applied podman registries fix"
elif [[ ! -f $REG && $search == *docker.io* ]]; then
  p "podman already resolves short names ($search): no fix needed"
else
  f "flk setup --fix did not apply registries fix (podman search: ${search:-none})"
fi
SYM_EXPECTED="$HOME/.local/bin/flk"
if grep -qF "Linked" /tmp/setup.out || [[ -L $SYM_EXPECTED ]]; then
  p "flk setup --fix: PATH symlink in place ($SYM_EXPECTED)"
else
  f "flk setup --fix did not create PATH symlink ($SYM_EXPECTED)"
fi

# ---------- 5. verify fix artifacts on disk --------------------------------
hdr "Step 5: verify fix artifacts"
if [[ -f $REG ]] && grep -q 'docker.io' "$REG"; then
  p "registries drop-in exists: $REG"
elif [[ $search == *docker.io* ]]; then
  p "no registries drop-in needed"
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
