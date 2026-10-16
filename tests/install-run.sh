#!/usr/bin/env bash
# Shared install-test script for Ubuntu, Arch and Fedora VMs.
# Executed inside a Firecracker VM by tests/cases/60-install-ubuntu.sh,
# 61-install-arch.sh and 62-install-fedora.sh. The flk source tree is
# mounted at /flk-src via a volume.
#
# The steps run as a new user, the way someone installs flk: as root only
# what they'd run with sudo (packages, setup-host.sh's kvm group). KVM,
# bridge, taps, port helper and boot service checks are expected to fail
# (no nested virt, no setup-host.sh). Everything else should pass.
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

# ---------- 0. a user who installs flk ------------------------------------
# A password and no NOPASSWD rule: anything that waits for sudo's password
# shows up as "a terminal is required" (stdin is /dev/null) and fails step 8.
U=flkuser
hdr "Step 0: create $U"
# The test's own tools (runuser, setpriv): not in Fedora's container image.
command -v runuser >/dev/null && command -v setpriv >/dev/null ||
  case "$PKG_MGR" in dnf) dnf install -y -q util-linux ;; pacman) pacman -Sy --noconfirm -q util-linux ;; apt) apt-get update -qq && apt-get install -y -qq util-linux ;; esac >/dev/null 2>&1
command -v runuser >/dev/null || f "no runuser: the user steps can't run"
useradd -m -s /bin/bash "$U" && echo "$U:not-a-real-password" | chpasswd
for g in sudo wheel; do getent group $g >/dev/null && usermod -aG $g "$U"; done
UHOME=$(getent passwd "$U" | cut -d: -f6)
[[ -d $UHOME ]] && p "$U created ($UHOME)" || f "could not create $U"
as_user() { timeout 900 runuser -l "$U" -c "$1" </dev/null; } # a fresh login
OUTS=()
run_as() { # NAME CMD: as the user, output to /tmp/NAME.out (and the log)
  as_user "$2" 2>&1 | tee "/tmp/$1.out"; OUTS+=("/tmp/$1.out")
}

# ---------- 1. sanity before install: should report missing packages ------
hdr "Step 1: sanity before install, as $U (expect package failures)"
run_as sanity-pre "$FLK_SRC/flk-sanity.sh --no-doctor --skip kvm,host,firewall" || true
if grep -qE '^[0-9]+ passed, [1-9][0-9]* failed' /tmp/sanity-pre.out && grep -q '^Install missing' /tmp/sanity-pre.out; then
  p "sanity correctly reports what needs installing"
else
  f "sanity ran but gave no failures before install — unexpected"
fi

# ---------- 2. install packages: the command sanity suggested --------------
# Running sanity's own command is what tests its PKG table (per distro). As
# root: the user would type it with sudo, which isn't installed yet.
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
# archlinux:latest and fedora:latest ship newuidmap/newgidmap without the
# file capabilities their packages set (cap_setuid, cap_setgid; checked in
# the packages and the registry layers). Reinstall, so rootless podman works
# as on a real install.
case "$PKG_MGR" in
  pacman) pacman -S --noconfirm shadow ;;
  dnf)    dnf reinstall -y -q shadow-utils ;;
esac >/dev/null 2>&1
# podman needs cgroup v2; systemd mounts it at boot on a real host, but the
# Firecracker init doesn't.
grep -q cgroup2 /proc/mounts 2>/dev/null || mount -t cgroup2 none /sys/fs/cgroup 2>/dev/null || true

# ---------- 3. sanity after install: packages pass for the user -------------
# Includes the container engine: `podman info` as the user (rootless).
hdr "Step 3: sanity after install, as $U (packages only)"
run_as sanity-pkgs "$FLK_SRC/flk-sanity.sh --no-doctor --only packages" || true
if grep -qF "0 failed" /tmp/sanity-pkgs.out && grep -qF "0 warnings" /tmp/sanity-pkgs.out; then
  p "all package checks pass after install (rootless podman works)"
else
  f "package checks still failing after install — see above"
  as_user 'podman info 2>&1 >/dev/null | tail -5; grep "^$USER:" /etc/subuid /etc/subgid'
fi

# ---------- 4. the kvm group, as setup-host.sh does it ----------------------
hdr "Step 4: kvm group"
getent group kvm >/dev/null || groupadd -r kvm # udev makes it on a real host
run_as sanity-kvm0 "$FLK_SRC/flk-sanity.sh --no-doctor --only host" || true
grep -qF "$U not in kvm group yet" /tmp/sanity-kvm0.out &&
  p "before: sanity says $U isn't in kvm yet" || f "before: sanity didn't say $U isn't in kvm"
usermod -aG kvm "$U" # what setup-host.sh does
# A session from before usermod: same user, without the new group.
timeout 120 setpriv --reuid="$U" --regid="$U" --clear-groups \
  env -i HOME="$UHOME" USER="$U" PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  "$FLK_SRC/flk-sanity.sh" --no-doctor --only host </dev/null 2>&1 | tee /tmp/sanity-kvm1.out || true
grep -qF "this login doesn't have it yet" /tmp/sanity-kvm1.out &&
  p "old login: sanity says to log out and back in" || f "old login: sanity missed the stale session"
run_as sanity-kvm2 "$FLK_SRC/flk-sanity.sh --no-doctor --only host" || true
grep -qF "$U in kvm group" /tmp/sanity-kvm2.out &&
  p "new login: $U is in kvm" || f "new login: sanity doesn't see $U in kvm"

# ---------- 5. flk setup --fix, as the user --------------------------------
hdr "Step 5: flk setup --fix, as $U"
login_path=$(as_user 'echo $PATH')
run_as setup "$FLK_SRC/bin/flk setup --fix" || true
if grep -qF "firecracker" /tmp/setup.out && grep -qF "guest kernel" /tmp/setup.out &&
   [[ -d $UHOME/.local/share/flk ]]; then
  p "firecracker and guest kernel downloaded into $UHOME/.local/share/flk"
else
  f "flk setup did not download expected assets"
fi
# Fedora's podman already searches docker.io: nothing to fix there.
search=$(as_user "podman info --format '{{json .Registries.search}}'" 2>/dev/null)
REG="$UHOME/.config/containers/registries.conf.d/50-flk-docker-io.conf"
if grep -qE 'Configured podman|flk-docker-io' /tmp/setup.out && grep -q docker.io "$REG" 2>/dev/null; then
  p "--fix: podman short names (the user's $REG)"
elif [[ ! -f $REG && $search == *docker.io* ]]; then
  p "podman already resolves short names ($search): no fix needed"
else
  f "--fix did not set up podman short names (podman search: ${search:-none})"
fi
SYM="$UHOME/.local/bin/flk"
if [[ -L $SYM && $(readlink "$SYM") == "$FLK_SRC/bin/flk" ]]; then
  p "--fix: $SYM -> $FLK_SRC/bin/flk"
else
  f "PATH symlink wrong (got: $(ls -la "$SYM" 2>&1 || echo missing))"
fi
# setup says how to get ~/.local/bin on PATH exactly when the shell lacks it
if [[ ":$login_path:" == *":$UHOME/.local/bin:"* ]]; then
  ! grep -qF "isn't on PATH" /tmp/setup.out &&
    p "~/.local/bin was on PATH: no PATH hint" || f "PATH hint although ~/.local/bin was on PATH"
else
  grep -qF "isn't on PATH" /tmp/setup.out &&
    p "~/.local/bin wasn't on PATH: setup said how to add it" || f "no PATH hint, and ~/.local/bin wasn't on PATH"
fi

# ---------- 6. flk on PATH in a new login ----------------------------------
hdr "Step 6: flk on PATH, new login"
if found=$(as_user 'command -v flk'); then
  p "a new login finds flk ($found)"
elif as_user 'export PATH="$HOME/.local/bin:$PATH"; flk version' >/dev/null 2>&1; then
  p "a new login needs the PATH line (the distro doesn't add ~/.local/bin); setup's line works"
else
  f "flk not runnable from a new login, even with setup's PATH line"
fi

# ---------- 7. final sanity: only host-level items should fail -------------
hdr "Step 7: full sanity, as $U (only KVM/bridge/host items expected to fail)"
run_as sanity-final "$FLK_SRC/flk-sanity.sh" || true
unexpected=$(grep -E '^\s+✘' /tmp/sanity-final.out | grep -vE "$EXPECTED_HOST_FAILS" || true)
if [[ -n $unexpected ]]; then
  f "unexpected failures in final sanity:"
  echo "$unexpected" >&2
else
  p "final sanity: only expected host-level items fail (KVM/bridge/taps)"
fi

# ---------- 8. nothing waited for a sudo password --------------------------
hdr "Step 8: no sudo prompts"
if grep -lE 'a terminal is required|a password is required|\[sudo\] password' "${OUTS[@]}"; then
  f "something asked sudo for a password (files above)"
else
  p "no sudo password prompts in any step"
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
