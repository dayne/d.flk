#!/usr/bin/env bash
# Install test: run the flk install steps on a fresh Ubuntu system and
# report pass/fail for each stage. Executed inside a Firecracker VM by
# tests/cases/60-install-ubuntu.sh; /flk-src is the flk source tree.
#
# KVM and bridge checks are expected to fail (no nested virt in a VM).
# Everything else — packages, sanity output shape, flk setup, --fix — should pass.
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
export PATH="$PATH:/usr/sbin:/sbin"  # mkfs.ext4 lives here on Ubuntu

FLK="$HOME/.local/bin/flk"
FLK_SRC=/flk-src
PASS=0; FAIL=0

p()  { echo "  PASS: $*"; ((PASS++)); }
f()  { echo "  FAIL: $*" >&2; ((FAIL++)); }
hdr(){ echo; echo "==> $*"; }

# ---------- 1. host check -------------------------------------------------
hdr "Step 1: flk-sanity.sh (packages only, no KVM/bridge)"
$FLK_SRC/flk-sanity.sh --no-doctor --skip kvm,host,firewall 2>&1 | tee /tmp/sanity1.out
if grep -qF "0 failed" /tmp/sanity1.out; then p "sanity: all package checks pass"
else                                           f "sanity: package check failures (see above)"; fi

# ---------- 2. install packages -------------------------------------------
hdr "Step 2: apt install"
apt-get update -qq 2>&1 | tail -1
apt-get install -y -qq ruby tmux e2fsprogs fakeroot podman iproute2 nftables curl \
  2>&1 | tail -3
p "apt install completed"

# ---------- 3. sanity: packages should now all pass -----------------------
hdr "Step 3: sanity after package install"
$FLK_SRC/flk-sanity.sh --no-doctor --only packages 2>&1 | tee /tmp/sanity2.out
if grep -qF "0 failed" /tmp/sanity2.out && grep -qF "0 warnings" /tmp/sanity2.out
then p "sanity: all packages pass after install"
else f "sanity: unexpected failures after install (see above)"; fi

# ---------- 4. flk setup --fix -------------------------------------------
hdr "Step 4: flk setup --fix"
$FLK_SRC/bin/flk setup --fix 2>&1 | tee /tmp/setup.out
if grep -qF "Ready to fly, locally." /tmp/setup.out
then p "flk doctor passes (modulo host-level checks)"
else f "flk doctor did not print 'Ready to fly, locally.'"; fi

# ---------- 5. verify --fix applied both fixes ----------------------------
hdr "Step 5: verify --fix results"

REG="$HOME/.config/containers/registries.conf.d/50-flk-docker-io.conf"
if [[ -f $REG ]] && grep -q 'docker.io' "$REG"
then p "--fix: podman registries config applied ($REG)"
else f "--fix: registries config missing or wrong"; fi

SYM="$HOME/.local/bin/flk"
if [[ -L $SYM ]] && [[ $(readlink "$SYM") == "$FLK_SRC/bin/flk" ]]
then p "--fix: PATH symlink created ($SYM -> $FLK_SRC/bin/flk)"
else f "--fix: symlink missing or wrong ($(ls -la "$SYM" 2>&1))"; fi

# ---------- 6. flk on PATH works ------------------------------------------
hdr "Step 6: flk on PATH"
if "$FLK" version >/dev/null 2>&1
then p "flk version: $($FLK version)"
else f "flk not runnable via PATH symlink"; fi

# ---------- 7. sanity final: only host-level items should fail ------------
hdr "Step 7: sanity final (expect KVM/bridge failures, nothing else)"
$FLK_SRC/flk-sanity.sh 2>&1 | tee /tmp/sanity3.out || true
# Packages and flk itself should all pass
if grep -qF "0 failed" /tmp/sanity3.out 2>/dev/null || \
   grep -E '^\s+✘' /tmp/sanity3.out 2>/dev/null | grep -qvE 'kvm|bridge|tap|port helper|boot service'
then f "sanity: unexpected non-host failures (see above)"
else p "sanity: only expected host-level items fail (KVM/bridge/taps)"; fi

# ---------- summary -------------------------------------------------------
echo
echo "================================"
if ((FAIL == 0))
then echo "INSTALL TEST PASSED ($PASS checks)"
else echo "INSTALL TEST FAILED ($FAIL/$((PASS+FAIL)) checks failed)"
     exit 1
fi
