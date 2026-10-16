#!/usr/bin/env bash
# flk-sanity.sh: is this host ready to run flk? Read-only, safe to re-run.
#
#   ./flk-sanity.sh                 core checks, then `flk doctor` if they pass
#   ./flk-sanity.sh --online        also check GitHub/S3 reachability (flk setup)
#   ./flk-sanity.sh --only kvm,packages   --skip online   --no-doctor   --quiet
#
# Core checks cover what you need before flk itself can run: hardware,
# packages, the kvm group, and a working `flk` CLI. Once those pass, the
# runtime health checks (bridge, taps, firecracker, kernel...) come from
# `flk doctor`, whose results are folded into this report.
#
# Fix the first failure, re-run, repeat. The usual sequence is:
#   install packages -> sudo ./setup-host.sh -> log out/in -> flk setup
#
# Adding a check: write a check_* function that ends in pass/fail/warn/skip,
# then add "group:function [args]" to CHECKS below.
#
# Exit: 0 all passed, 1 any failure, 2 warnings only.
set -uo pipefail
export PATH="$PATH:/usr/sbin:/sbin" # mkfs.ext4 lives here on Debian/Ubuntu

FLK_SRC=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
FLK_BIN="$FLK_SRC/bin/flk"
FLK_HOME=${FLK_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/flk}
FLK_BRIDGE=${FLK_BRIDGE:-flkbr0}

RUBY_MIN=3.0     # endless `def x = ...` methods
E2FS_MIN=1.43    # mkfs.ext4 -d
DISK_MIN_GB=5

# ---------- registry ----------
# Runs in order; earlier failures produce the "next step" hint.
# Quote entries that take args; args are split on whitespace.
CHECKS=(
  platform:check_linux
  platform:check_arch
  platform:check_distro
  kvm:check_cpu_virt
  kvm:check_kvm_module
  kvm:check_dev_kvm
  "packages:check_cmd sudo"
  packages:check_ruby
  "packages:check_cmd tmux"
  packages:check_mkfs_ext4
  "packages:check_cmd fakeroot"
  "packages:check_cmd curl"
  "packages:check_cmd tar"
  "packages:check_cmd sha256sum"
  packages:check_gnu_cp
  "packages:check_cmd ip"
  "packages:check_cmd nft"
  "packages:check_cmd sysctl"
  packages:check_docker_iptables
  packages:check_engine
  host:check_dev_tun
  host:check_kvm_group
  host:check_disk_space
  firewall:check_ufw
  firewall:check_firewalld
  firewall:check_docker_forward
  firewall:check_port_helper
  flk:check_flk_runs
  flk:check_flk_on_path
  "online:check_url github-api https://api.github.com"
  "online:check_url firecracker-ci-s3 https://s3.amazonaws.com/spec.ccfc.min/?list-type=2&max-keys=1"
)
OPTIONAL_GROUPS=" online "   # skipped unless asked for

# command -> "apt|pacman|dnf" package names
declare -A PKG=(
  [sudo]="sudo|sudo|sudo"
  [ruby]="ruby|ruby|ruby"
  [tmux]="tmux|tmux|tmux"
  [mkfs.ext4]="e2fsprogs|e2fsprogs|e2fsprogs"
  [fakeroot]="fakeroot|fakeroot|fakeroot"
  [curl]="curl|curl|curl"
  [tar]="tar|tar|tar"
  [sha256sum]="coreutils|coreutils|coreutils"
  [cp]="coreutils|coreutils|coreutils"
  [ip]="iproute2|iproute2|iproute"
  [nft]="nftables|nftables|nftables"
  [sysctl]="procps|procps-ng|procps-ng"
  [iptables]="iptables|iptables|iptables"
  [podman]="podman|podman|podman"
)

# ---------- output + bookkeeping ----------
declare -i N_PASS=0 N_FAIL=0 N_WARN=0 N_SKIP=0
HINTS=() NEXT="" MISSING_PKGS=() ONLY="" SKIP="" QUIET=0 RUN_DOCTOR=1 COLOR=1
PKG_MGR="" DISTRO=""
[[ -t 1 && -z ${NO_COLOR:-} ]] || COLOR=0

c() { ((COLOR)) && printf '\e[%sm%s\e[0m' "$1" "$2" || printf '%s' "$2"; }

_record() { # STATUS MESSAGE [HINT]
  local st=$1 msg=$2 hint=${3:-} icon
  case $st in
    PASS) N_PASS+=1; icon=$(c 32 ✔) ;;
    FAIL) N_FAIL+=1; icon=$(c 31 ✘) ;;
    WARN) N_WARN+=1; icon=$(c 33 !) ;;
    SKIP) N_SKIP+=1; icon=$(c 90 -) ;;
  esac
  if ((QUIET)) && [[ $st == PASS || $st == SKIP ]]; then return 0; fi
  printf '  %s %s%s\n' "$icon" "$msg" "${hint:+  $(c 90 "-> $hint")}"
  if [[ -n $hint && $st != SKIP ]]; then add_hint "$hint"; fi
  if [[ $st == FAIL && -z $NEXT ]]; then NEXT=${hint:-$msg}; fi
  return 0
}
pass() { _record PASS "$1"; }
fail() { _record FAIL "$1" "${2:-}"; }
warn() { _record WARN "$1" "${2:-}"; }
skip() { _record SKIP "$1" "${2:-}"; }

add_hint() {
  local h
  for h in "${HINTS[@]+"${HINTS[@]}"}"; do [[ $h == "$1" ]] && return; done
  HINTS+=("$1")
}

# ---------- helpers ----------
have() { command -v "$1" >/dev/null 2>&1; }

version_ge() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" == "$2" ]]; }

detect_distro() {
  [[ -r /etc/os-release ]] && . /etc/os-release
  DISTRO=${PRETTY_NAME:-unknown}
  case " ${ID:-} ${ID_LIKE:-} " in
    *" debian "*|*" ubuntu "*) PKG_MGR=apt ;;
    *" arch "*)                PKG_MGR=pacman ;;
    *" fedora "*|*" rhel "*)   PKG_MGR=dnf ;;
  esac
}

pkg_for() { # CMD -> package name for this distro (or the command itself)
  local names=${PKG[$1]:-} i
  [[ -n $names ]] || { echo "$1"; return; }
  case $PKG_MGR in apt) i=1 ;; pacman) i=2 ;; dnf) i=3 ;; *) i=1 ;; esac
  cut -d'|' -f"$i" <<<"$names"
}

fail_pkg() { # MESSAGE CMD: fail, and queue CMD's package for the install line
  local p; p=$(pkg_for "$2")
  [[ " ${MISSING_PKGS[*]+"${MISSING_PKGS[*]}"} " == *" $p "* ]] || MISSING_PKGS+=("$p")
  fail "$1" "$(install_cmd "$p")"
}

install_cmd() {
  case $PKG_MGR in
    apt)    echo "sudo apt install -y $*" ;;
    pacman) echo "sudo pacman -S --needed $*" ;;
    dnf)    echo "sudo dnf install -y $*" ;;
    *)      echo "install: $*" ;;
  esac
}

# ---------- checks: platform ----------
check_linux() {
  [[ $(uname -s) == Linux ]] && pass "Linux $(uname -r)" || fail "not Linux ($(uname -s))" "flk needs Linux + KVM"
}

check_arch() {
  case $(uname -m) in
    x86_64)  pass "arch x86_64" ;;
    aarch64) warn "arch aarch64 (less tested; stop falls back to SIGTERM)" ;;
    *)       fail "arch $(uname -m) unsupported" "Firecracker supports x86_64 and aarch64" ;;
  esac
}

check_distro() {
  [[ -n $PKG_MGR ]] && pass "$DISTRO ($PKG_MGR)" ||
    warn "$DISTRO: unknown package manager" "package hints below assume Debian names"
}

# ---------- checks: kvm ----------
check_cpu_virt() {
  local vm=""
  have systemd-detect-virt && vm=$(systemd-detect-virt --vm 2>/dev/null) && [[ $vm != none ]] || vm=""
  if grep -Eqw 'vmx|svm' /proc/cpuinfo 2>/dev/null; then
    pass "CPU virtualization (vmx/svm)${vm:+, nested inside $vm}"
  elif [[ -n $vm ]]; then
    fail "no vmx/svm: running inside $vm without nested virtualization" "enable nested virt on the hypervisor"
  else
    fail "CPU virtualization not exposed" "enable VT-x/AMD-V in BIOS/UEFI"
  fi
}

check_kvm_module() {
  if [[ -d /sys/module/kvm_intel || -d /sys/module/kvm_amd || $(uname -m) == aarch64 && -d /sys/module/kvm ]]; then
    pass "kvm module loaded"
  else
    fail "kvm module not loaded" "sudo modprobe kvm_intel  # or kvm_amd"
  fi
}

check_dev_kvm() {
  [[ -c /dev/kvm ]] && pass "/dev/kvm present" || fail "/dev/kvm missing" "load kvm_intel/kvm_amd; check BIOS virtualization"
}

# ---------- checks: packages ----------
check_cmd() { # CMD
  have "$1" && pass "$1" || fail_pkg "$1 not found" "$1"
}

check_ruby() {
  have ruby || { fail_pkg "ruby not found (need >= $RUBY_MIN)" ruby; return; }
  local v; v=$(ruby -e 'print RUBY_VERSION' 2>/dev/null)
  version_ge "$v" "$RUBY_MIN" && pass "ruby $v" || fail "ruby $v too old (need >= $RUBY_MIN)" "install a newer ruby (distro, rbenv, or mise)"
}

check_mkfs_ext4() {
  have mkfs.ext4 || { fail_pkg "mkfs.ext4 not found" mkfs.ext4; return; }
  local v; v=$(mkfs.ext4 -V 2>&1 | awk 'NR==1{print $2}')
  version_ge "$v" "$E2FS_MIN" && pass "mkfs.ext4 (e2fsprogs $v)" ||
    fail "e2fsprogs $v too old (need >= $E2FS_MIN for mkfs.ext4 -d)" "upgrade e2fsprogs"
}

check_gnu_cp() {
  cp --help 2>&1 | grep -q -- '--reflink' && pass "GNU cp (--reflink)" ||
    fail_pkg "cp lacks --reflink (not GNU coreutils?)" cp
}

check_docker_iptables() {
  have docker || { skip "iptables (only needed alongside docker)"; return; }
  have iptables && pass "iptables (docker present)" ||
    fail_pkg "docker present but iptables missing (setup-host.sh adds DOCKER-USER rules)" iptables
}

check_engine() {
  local eng=${FLK_ENGINE:-}
  if [[ -z $eng ]]; then
    for eng in podman docker ""; do [[ -n $eng ]] && have "$eng" && break; done
  fi
  [[ -n $eng ]] || { fail_pkg "no container engine (podman or docker)" podman; return; }
  have "$eng" || { fail "FLK_ENGINE=$eng not found"; return; }
  if "$eng" info >/dev/null 2>&1; then
    pass "container engine: $eng"
  elif [[ $eng == docker ]]; then
    fail "docker installed but not usable by $USER" "sudo usermod -aG docker $USER (then log out/in), or install podman"
  else
    fail "$eng installed but '$eng info' fails" "run '$eng info' to see why"
  fi
}

# ---------- checks: host ----------
check_dev_tun() {
  [[ -c /dev/net/tun ]] && pass "/dev/net/tun (tap devices)" || fail "/dev/net/tun missing" "sudo modprobe tun"
}

# setup-host.sh adds you to kvm, but the current login only sees it after re-login.
check_kvm_group() {
  getent group kvm >/dev/null || { skip "kvm group (none on this system; /dev/kvm perms decide)"; return; }
  local in_db=0 in_session=0
  id -nG "$USER" | grep -qw kvm && in_db=1
  id -nG | grep -qw kvm && in_session=1
  if ((in_session)); then pass "$USER in kvm group"
  elif ((in_db)); then fail "$USER added to kvm, but this login doesn't have it yet" "log out and back in (or: newgrp kvm)"
  else warn "$USER not in kvm group yet" "sudo ./setup-host.sh"
  fi
}

check_disk_space() {
  local d=$FLK_HOME
  while [[ ! -d $d ]]; do d=$(dirname "$d"); done
  local gb=$(( $(df -Pk "$d" | awk 'NR==2{print $4}') / 1024 / 1024 ))
  ((gb >= DISK_MIN_GB)) && pass "disk: ${gb}GB free for $FLK_HOME" ||
    warn "disk: only ${gb}GB free for $FLK_HOME (rootfs images add up)" "free space or set FLK_HOME elsewhere"
}

# ---------- checks: firewall ----------
# flk's nft table accepts bridge traffic, but a DROP on the FORWARD hook from
# another firewall still wins: VMs boot yet can't reach anything. setup-host.sh
# punches holes for the bridge; these checks confirm they're there.
FW_HINT="sudo ./setup-host.sh (allows forwarding on $FLK_BRIDGE)"

check_ufw() {
  have ufw || { skip "ufw not installed"; return; }
  local enabled policy rules
  enabled=$(sed -n 's/^ENABLED=//p' /etc/ufw/ufw.conf 2>/dev/null)
  policy=$(sed -n 's/^DEFAULT_FORWARD_POLICY="\{0,1\}\([A-Z]*\).*/\1/p' /etc/default/ufw 2>/dev/null)
  if [[ $enabled != yes ]]; then
    pass "ufw installed but disabled (if you enable it, re-run setup-host.sh)"
  elif [[ $policy == ACCEPT ]]; then
    pass "ufw forward policy ACCEPT"
  elif rules=$(sudo -n ufw status 2>/dev/null); then
    if [[ $(grep -E "on $FLK_BRIDGE" <<<"$rules" | grep -c 'ALLOW FWD') -ge 2 ]]; then
      pass "ufw allows forwarding on $FLK_BRIDGE"
    else
      fail "ufw drops forwarded traffic and has no rules for $FLK_BRIDGE" "$FW_HINT"
    fi
  else
    warn "ufw is enabled with forward policy $policy; can't verify $FLK_BRIDGE rules without root" \
      "sudo ufw status | grep $FLK_BRIDGE  (missing? $FW_HINT)"
  fi
}

check_firewalld() {
  have firewall-cmd && firewall-cmd --state >/dev/null 2>&1 || { skip "firewalld not running"; return; }
  local zone; zone=$(firewall-cmd --get-zone-of-interface="$FLK_BRIDGE" 2>/dev/null)
  [[ $zone == trusted ]] && pass "firewalld: $FLK_BRIDGE in trusted zone" ||
    fail "firewalld running and $FLK_BRIDGE is in zone '${zone:-none}', not trusted" "$FW_HINT"
}

check_docker_forward() {
  have docker || { skip "docker not installed (no DOCKER-USER rules needed)"; return; }
  if ! sudo -n iptables -nL DOCKER-USER >/dev/null 2>&1; then
    warn "docker installed; can't verify DOCKER-USER rules without root" \
      "sudo iptables -nL DOCKER-USER | grep $FLK_BRIDGE  (missing? $FW_HINT)"
  elif sudo -n iptables -C DOCKER-USER -i "$FLK_BRIDGE" -j ACCEPT 2>/dev/null &&
       sudo -n iptables -C DOCKER-USER -o "$FLK_BRIDGE" -j ACCEPT 2>/dev/null; then
    pass "DOCKER-USER accepts $FLK_BRIDGE traffic"
  else
    fail "docker's FORWARD DROP will blackhole $FLK_BRIDGE (no DOCKER-USER rules)" "$FW_HINT"
  fi
}

# [[services.ports]] forwarding: flk refills an nft map through this helper.
check_port_helper() {
  local h=/usr/local/libexec/flk-ports
  if [[ ! -x $h ]]; then
    warn "port forwarding not set up (no $h)" "sudo ./setup-host.sh"
  elif ! sudo -n -l "$h" >/dev/null 2>&1; then
    warn "$h installed but $USER can't run it via sudo without a password" "sudo ./setup-host.sh"
  else
    pass "port forwarding helper ($h)"
  fi
}

# ---------- checks: flk ----------
check_flk_runs() {
  [[ -x $FLK_BIN ]] || { fail "$FLK_BIN missing or not executable"; return; }
  local out
  if out=$("$FLK_BIN" version 2>&1); then pass "$out runs ($FLK_BIN)"
  else fail "bin/flk fails to start: ${out%%$'\n'*}" "fix ruby first (see above)"
  fi
}

check_flk_on_path() {
  local p; p=$(command -v flk 2>/dev/null)
  if [[ -z $p ]]; then
    warn "flk not on PATH" "mkdir -p ~/.local/bin && ln -s $FLK_BIN ~/.local/bin/flk"
  elif [[ $(readlink -f "$p") != "$(readlink -f "$FLK_BIN")" ]]; then
    warn "flk on PATH ($p) is a different checkout than $FLK_SRC"
  else
    pass "flk on PATH ($p)"
  fi
}

# ---------- checks: online ----------
check_url() { # LABEL URL: any HTTP response counts as reachable
  curl -s -o /dev/null --max-time 8 "$2" && pass "reachable: $1" ||
    fail "unreachable: $1 ($2)" "check network/proxy; flk setup downloads from here"
}

# ---------- flk doctor ----------
# Runtime health is doctor's job; fold its checks (doctor --json) into our
# counts. Ruby is a core check, so it's there by the time this runs.
run_doctor() {
  ((QUIET)) || echo $'\n'"$(c 1 "flk doctor")"
  if ((N_FAIL)); then skip "skipped: fix the core failures above first"; return; fi
  local out rows st label hint
  if ! out=$("$FLK_BIN" doctor --json 2>&1); then
    fail "flk doctor crashed: ${out##*$'\n'}"; return
  fi
  if ! rows=$(ruby -rjson -e 'JSON.parse($stdin.read).fetch("checks").each { |c|
      puts [c.fetch("status"), c.fetch("label"), c["hint"]].join("\t") }' <<<"$out" 2>&1); then
    fail "flk doctor --json gave unreadable output: ${out%%$'\n'*}"; return
  fi
  while IFS=$'\t' read -r st label hint; do
    case $st in
      pass) pass "$label" ;;
      warn) warn "$label" "$hint" ;;
      *)    fail "$label" "$hint" ;;
    esac
  done <<<"$rows"
}

# ---------- driver ----------
usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

parse_args() {
  while (($#)); do
    case $1 in
      --only)      ONLY+=" ${2//,/ } "; shift ;;
      --skip)      SKIP+=" ${2//,/ } "; shift ;;
      --online)    OPTIONAL_GROUPS=${OPTIONAL_GROUPS/ online / } ;;
      --no-doctor) RUN_DOCTOR=0 ;;
      --quiet|-q)  QUIET=1 ;;
      --no-color)  COLOR=0 ;;
      -h|--help)   usage ;;
      *)           echo "unknown option: $1" >&2; usage 1 ;;
    esac
    shift
  done
}

wanted() { # GROUP
  [[ " $SKIP " == *" $1 "* ]] && return 1
  [[ -n ${ONLY// } ]] && { [[ " $ONLY " == *" $1 "* ]]; return; }
  [[ " $OPTIONAL_GROUPS " != *" $1 "* ]]
}

run_checks() {
  local entry group fn last=""
  for entry in "${CHECKS[@]}"; do
    group=${entry%%:*}
    wanted "$group" || continue
    [[ $group != "$last" ]] && ! ((QUIET)) && echo $'\n'"$(c 1 "$group")"
    last=$group
    read -ra fn <<<"${entry#*:}"
    "${fn[@]}"
  done
}

summary() {
  echo
  printf '%s passed, %s failed, %s warnings, %s skipped\n' \
    "$(c 32 $N_PASS)" "$(c 31 $N_FAIL)" "$(c 33 $N_WARN)" "$N_SKIP"
  if ((${#MISSING_PKGS[@]})); then
    echo; echo "Install missing packages:"; echo "  $(install_cmd "${MISSING_PKGS[@]}")"
  fi
  if ((N_FAIL + N_WARN)); then
    # Build deduplicated ordered step list from HINTS (already deduplicated by add_hint).
    # Package install command goes first if packages are missing.
    local -a steps=()
    local pkg_cmd="" h i found
    ((${#MISSING_PKGS[@]})) && pkg_cmd=$(install_cmd "${MISSING_PKGS[@]}")
    [[ -n $pkg_cmd ]] && steps+=("$pkg_cmd")
    for h in "${HINTS[@]+"${HINTS[@]}"}"; do
      found=0
      for ((i=0; i<${#steps[@]}; i++)); do [[ "${steps[$i]}" == "$h" ]] && found=1 && break; done
      ((found)) || steps+=("$h")
    done
    ((${#steps[@]})) || steps=("${NEXT:-see above}")
    echo
    if ((${#steps[@]} == 1)); then
      echo "Next step: $(c 1 "${steps[0]}")"
      ((N_FAIL)) && echo "Then re-run $0"
    else
      echo "Steps needed:"
      for ((i=0; i<${#steps[@]}; i++)); do
        printf '  %d. %s\n' "$((i+1))" "$(c 1 "${steps[$i]}")"
      done
      ((N_FAIL)) && echo "Re-run $0 after each step."
    fi
  else
    echo; echo "Host is ready for flk."
  fi
}

main() {
  parse_args "$@"
  detect_distro
  echo "flk sanity check: $FLK_SRC"
  run_checks
  if ((RUN_DOCTOR)) && wanted doctor; then run_doctor; fi
  summary
  ((N_FAIL)) && exit 1
  ((N_WARN)) && exit 2
  exit 0
}

main "$@"
