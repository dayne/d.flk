#!/usr/bin/env bash
# setup-host.sh: the only part of flk that needs root.
#
#   sudo ./setup-host.sh                    bridge + tap pool + NAT + port forwarding, kvm group
#                                           (networking only: what flk-net.service runs at boot)
#   sudo ./setup-host.sh --install-service  all of the above, plus the systemd units (networking,
#                                           flk's tmux server, machines); also the way to upgrade
#   sudo ./setup-host.sh --down             remove taps, bridge, NAT table
#   sudo ./setup-host.sh --uninstall        --down, plus remove the port helper, sudoers rule, service
#
# Env: FLK_BRIDGE (flkbr0)  FLK_SUBNET (172.30.0)  FLK_TAPS (16)  FLK_UPLINK (auto)
#      FLK_MIN_PORT (1024): lowest host port flk may forward
# Taps are owned by $SUDO_USER, so firecracker can open them without root.
# If Docker, ufw or firewalld is active, it also allows forwarding on the
# bridge there (their FORWARD drop rules would otherwise blackhole the VMs).
#
# Port forwarding ([[services.ports]] in flk.toml): host address:port -> machine.
# The rules here look up an nft map that flk refills as machines start and
# stop, through one root-owned helper (/usr/local/libexec/flk-ports) the user
# may run via sudo without a password. It only accepts tcp/udp ports to IPs
# inside the flk subnet, refuses host ports below FLK_MIN_PORT, and refuses
# ports a host process is listening on (e.g. sshd), so a flk.toml can't
# hijack the host's own services.
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }
user=${FLK_USER:-${SUDO_USER:-}}
[[ -n $user ]] || { echo "run via sudo (or set FLK_USER) so taps get the right owner" >&2; exit 1; }

bridge=${FLK_BRIDGE:-flkbr0}
subnet=${FLK_SUBNET:-172.30.0}
taps=${FLK_TAPS:-16}
min_port=${FLK_MIN_PORT:-1024}
[[ $min_port =~ ^[0-9]{1,5}$ ]] && ((10#$min_port >= 1 && 10#$min_port <= 65535)) ||
  { echo "FLK_MIN_PORT must be a port number (1-65535)" >&2; exit 1; }
min_port=$((10#$min_port))
uplink=${FLK_UPLINK:-$(ip -o route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')}
self=$(readlink -f "$0")
src=$(dirname "$self")
helper=/usr/local/libexec/flk-ports
sudoers=/etc/sudoers.d/flk

# Other firewalls on the FORWARD hook. Our nft table accepts bridge traffic,
# but an accept only ends our own chain: a DROP from Docker, ufw or
# firewalld in another chain still wins and silently blackholes the VMs.
# So punch a hole for the bridge in whichever of them is active.
ufw_active()       { command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; }
firewalld_active() { command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; }

firewall_allow() {
  # Docker sets FORWARD policy DROP; DOCKER-USER is its hook for user rules.
  if iptables -nL DOCKER-USER >/dev/null 2>&1; then
    iptables -C DOCKER-USER -i "$bridge" -j ACCEPT 2>/dev/null || iptables -I DOCKER-USER -i "$bridge" -j ACCEPT
    iptables -C DOCKER-USER -o "$bridge" -j ACCEPT 2>/dev/null || iptables -I DOCKER-USER -o "$bridge" -j ACCEPT
  fi
  # ufw's default forward policy is DROP. Route rules persist across reboots.
  if ufw_active; then
    ufw route allow in on "$bridge" >/dev/null
    ufw route allow out on "$bridge" >/dev/null
    echo "ufw: allowed forwarding on $bridge"
  elif command -v ufw >/dev/null; then
    echo "ufw is installed but inactive; if you enable it later, re-run: sudo $0"
  fi
  # firewalld rejects forwarded traffic unless a zone allows it.
  if firewalld_active; then
    firewall-cmd -q --zone=trusted --add-interface="$bridge" 2>/dev/null || true
    firewall-cmd -q --permanent --zone=trusted --add-interface="$bridge" 2>/dev/null || true
    echo "firewalld: $bridge added to the trusted zone"
  fi
}

firewall_remove() {
  if iptables -nL DOCKER-USER >/dev/null 2>&1; then
    iptables -D DOCKER-USER -i "$bridge" -j ACCEPT 2>/dev/null || true
    iptables -D DOCKER-USER -o "$bridge" -j ACCEPT 2>/dev/null || true
  fi
  if command -v ufw >/dev/null; then # rules may exist even if ufw is now inactive
    ufw route delete allow in on "$bridge" >/dev/null 2>&1 || true
    ufw route delete allow out on "$bridge" >/dev/null 2>&1 || true
  fi
  if firewalld_active; then
    firewall-cmd -q --zone=trusted --remove-interface="$bridge" 2>/dev/null || true
    firewall-cmd -q --permanent --zone=trusted --remove-interface="$bridge" 2>/dev/null || true
  fi
}

down() {
  for t in $(ls /sys/class/net | grep -E '^flktap[0-9]+$' || true); do ip link del "$t"; done
  ip link del "$bridge" 2>/dev/null || true
  nft delete table ip flk 2>/dev/null || true
  firewall_remove
  echo "flk networking removed"
}

# Root-owned copy of libexec/flk-ports: sudoers must never point at the repo,
# which the user can edit.
install_port_helper() {
  mkdir -p "$(dirname "$helper")"
  sed -e "s/@FLK_SUBNET@/$subnet/" -e "s/@FLK_MIN_PORT@/$min_port/" "$src/libexec/flk-ports" > "$helper.new"
  chown root:root "$helper.new"
  chmod 0755 "$helper.new"
  mv "$helper.new" "$helper"
  local tmp; tmp=$(mktemp)
  echo "$user ALL=(root) NOPASSWD: $helper" > "$tmp"
  visudo -cqf "$tmp" || { rm -f "$tmp"; echo "generated sudoers rule failed validation" >&2; exit 1; }
  install -o root -g root -m 0440 "$tmp" "$sudoers"
  rm -f "$tmp"
}

uninstall() {
  local unit
  for unit in flk-machines flk-tmux flk-net; do # machines first: they stop gracefully while the network is still up
    if [[ -f /etc/systemd/system/$unit.service ]]; then
      systemctl disable --now "$unit.service" 2>/dev/null || true
      rm -f "/etc/systemd/system/$unit.service"
    fi
  done
  systemctl daemon-reload 2>/dev/null || true
  down
  rm -f "$helper" "$sudoers"
  echo "flk host setup removed (the kvm group membership stays)"
}

install_service() {
  cat > /etc/systemd/system/flk-net.service <<EOF
[Unit]
Description=flk microVM bridge and tap pool
After=network-online.target docker.service ufw.service firewalld.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=FLK_USER=$user FLK_BRIDGE=$bridge FLK_SUBNET=$subnet FLK_TAPS=$taps FLK_MIN_PORT=$min_port
ExecStart=$self
ExecStop=$self --down

[Install]
WantedBy=multi-user.target
EOF

  local ruby_bin tmux_bin
  ruby_bin=$(sudo -u "$user" -H bash -lc 'command -v ruby' 2>/dev/null || command -v ruby)
  [[ -n $ruby_bin ]] || { echo "ruby not found for $user" >&2; exit 1; }
  tmux_bin=$(command -v tmux) || { echo "tmux not found" >&2; exit 1; }
  # Disks the machines need mounted: flk's state dir and every external
  # volume's dir (flk knows them). Start after those mounts, stop before them.
  # Plain /etc/fstab mounts are ordered that way already (local-fs.target);
  # this covers nofail and network mounts, so new volumes on such disks are
  # the only reason to re-run --install-service (flk doctor says when).
  local mount_dirs
  mount_dirs=$(sudo -u "$user" -H "$ruby_bin" "$src/bin/flk" context --all --json 2>/dev/null |
    "$ruby_bin" -rjson -e 'puts JSON.parse($stdin.read)["mount_dirs"].join(" ")' 2>/dev/null) ||
    mount_dirs=$(getent passwd "$user" | cut -d: -f6)
  local path_env
  path_env="PATH=$(dirname "$ruby_bin"):/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

  # flk's tmux server, as the user: every machine is a session in it, so
  # every firecracker lives in this unit, never in the login session of
  # whoever ran flk first (shutdown kills those before flk-machines can
  # stop anything). flk starts it through the port helper when it isn't
  # running (VM.ensure_server). Stopped on its own, it stops the machines
  # gracefully first; at shutdown flk-machines has done that already.
  cat > /etc/systemd/system/flk-tmux.service <<UNIT
[Unit]
Description=flk's tmux server: every flk machine runs in it
Wants=flk-net.service
After=flk-net.service remote-fs.target
RequiresMountsFor=$mount_dirs

[Service]
Type=forking
User=$user
Environment=$path_env
# tmux moves each pane into a tmux-spawn scope of the user's systemd when
# its server can reach that (these say where): machines must stay here.
UnsetEnvironment=XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS
ExecStart=$tmux_bin -L flk start-server \; set-option -g exit-empty off
# Only when systemd stops a server it owns (MAINPID set). It also runs this
# when ExecStart found a server already running elsewhere (flk-machines
# started it, before this unit existed) or after the server died: stopping
# machines then would take down a working host at install time.
ExecStop=/bin/sh -c 'test -n "\${MAINPID}" || exit 0; exec $ruby_bin $src/bin/flk stop-all'
TimeoutStopSec=330

[Install]
WantedBy=multi-user.target
UNIT

  # Machines: `flk resume` once the network and the tmux server are up,
  # `flk stop-all` (graceful, remembering them) at shutdown, before the
  # tmux server stops. Runs as the user, with their ruby on PATH. Wants,
  # not Requires, flk-tmux: a tmux server that died mustn't take this unit
  # (and its stop-all at shutdown) down with it.
  cat > /etc/systemd/system/flk-machines.service <<UNIT
[Unit]
Description=flk machines: resume at boot, stop gracefully at shutdown
Requires=flk-net.service
Wants=flk-tmux.service
After=flk-net.service flk-tmux.service remote-fs.target
RequiresMountsFor=$mount_dirs

[Service]
Type=oneshot
RemainAfterExit=yes
User=$user
Environment=$path_env
Environment=FLK_BRIDGE=$bridge FLK_SUBNET=$subnet FLK_TAPS=$taps
# '-': a machine that fails to resume must not fail the unit (which would kill the others)
ExecStart=-$ruby_bin $src/bin/flk resume
ExecStop=$ruby_bin $src/bin/flk stop-all
TimeoutStartSec=20min
# kill_timeout is at most 300s, and stop-all stops machines in parallel
TimeoutStopSec=330

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable --now flk-net.service
  systemctl enable --now flk-tmux.service
  systemctl enable --now flk-machines.service
  echo "installed and started flk-net.service, flk-tmux.service and flk-machines.service"
}

service=0
case "${1:-}" in
  --down) down; exit 0 ;;
  --install-service) service=1 ;; # the setup below first: it's idempotent, and units and helper go together
  --uninstall) uninstall; exit 0 ;;
  "") ;;
  *) echo "usage: sudo $0 [--down|--install-service|--uninstall]" >&2; exit 1 ;;
esac

# KVM access
[[ -e /dev/kvm ]] || { echo "/dev/kvm missing: enable VT-x/AMD-V and load kvm_intel or kvm_amd" >&2; exit 1; }
added_kvm=0
if getent group kvm >/dev/null && ! id -nG "$user" | grep -qw kvm; then
  usermod -aG kvm "$user"; added_kvm=1
  echo "added $user to group kvm (log out/in, or: newgrp kvm)"
fi

# Bridge
ip link show "$bridge" &>/dev/null || ip link add "$bridge" type bridge
ip addr replace "${subnet}.1/24" dev "$bridge"
ip link set "$bridge" up

# Tap pool owned by the user
for ((i = 0; i < taps; i++)); do
  t="flktap$i"
  ip link show "$t" &>/dev/null || ip tuntap add dev "$t" mode tap user "$user"
  ip link set "$t" master "$bridge" up
done

# Routing + NAT, in our own nft table so existing rulesets are untouched
sysctl -qw net.ipv4.ip_forward=1
nft -f - <<EOF
table ip flk
delete table ip flk
table ip flk {
  # host port -> machine ip . port, refilled by flk through the port helper:
  # addr_ports for ports bound to one host address ([flk] bind), ports for
  # the rest (any host address). A miss in addr_ports falls through.
  map addr_ports {
    type ipv4_addr . inet_proto . inet_service : ipv4_addr . inet_service
  }
  map ports {
    type inet_proto . inet_service : ipv4_addr . inet_service
  }
  # Traffic to a host address (LAN IP etc.), except loopback.
  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    fib daddr type local ip daddr != 127.0.0.0/8 dnat ip to ip daddr . meta l4proto . th dport map @addr_ports
    fib daddr type local ip daddr != 127.0.0.0/8 dnat ip to meta l4proto . th dport map @ports
  }
  # The same for connections made from the host itself.
  chain output {
    type nat hook output priority dstnat; policy accept;
    fib daddr type local ip daddr != 127.0.0.0/8 dnat ip to ip daddr . meta l4proto . th dport map @addr_ports
    fib daddr type local ip daddr != 127.0.0.0/8 dnat ip to meta l4proto . th dport map @ports
  }
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    ip saddr ${subnet}.0/24 oifname "${uplink}" masquerade
    # hairpin: a machine using a host port that maps to another machine
    ip saddr ${subnet}.0/24 ip daddr ${subnet}.0/24 ct status dnat masquerade
  }
  chain forward {
    type filter hook forward priority filter; policy accept;
    iifname "${bridge}" accept
    oifname "${bridge}" ct state established,related accept
    oifname "${bridge}" ct status dnat accept
  }
}
EOF

firewall_allow
install_port_helper

# Recreating the table emptied the port map; refill it for running machines.
sudo -u "$user" -H "$src/bin/flk" ports sync >/dev/null 2>&1 || true

echo "✔ bridge ${bridge} (${subnet}.1/24)"
echo "✔ tap pool: ${taps} taps owned by ${user}"
echo "✔ NAT via ${uplink}"
echo "✔ port helper: ${helper} (sudo no-password for ${user})"
if ((service)); then
  install_service
elif [[ -f /etc/systemd/system/flk-net.service && -z ${INVOCATION_ID:-} ]]; then
  # run by hand, not by flk-net at boot: its unit keeps the settings it was
  # installed with (FLK_TAPS...), so a reboot would undo changes made here
  echo "! boot units not refreshed; to keep these settings across reboots: sudo $0 --install-service"
fi
echo ""
if ((added_kvm)); then
  echo "Next: log out and back in (kvm group), then: ${src}/bin/flk setup --fix"
else
  echo "Next: ${src}/bin/flk setup --fix"
fi
[[ -f /etc/systemd/system/flk-machines.service ]] ||
  echo "Also, so machines come back after a reboot: sudo $0 --install-service"
