#!/usr/bin/env bash
# Runs inside a private network namespace where we're root (podman unshare
# + unshare -n; see tests/cases/06-ports-netns.sh): loads setup-host.sh's
# real nft table, installs a copy of the real port helper, and checks what
# connections to the host's addresses reach. Prints "ok ..." / "FAIL ...",
# then "done".
#   ports-netns.sh FLK_SRC WORKDIR
set -uo pipefail
src=$1 work=$2
subnet=172.30.0 bridge=vbr0 uplink=lan0 min_port=1024
lan=10.47.11.116 vip=10.47.11.3

ok() { echo "ok $*"; }
bad() { echo "FAIL $*"; }

ip link set lo up
ip link add name lan0 type dummy && ip link set lan0 up
ip addr add $lan/24 dev lan0 && ip addr add $vip/24 dev lan0
ip link add name vbr0 type dummy && ip link set vbr0 up
for a in 10 11 12 13; do ip addr add $subnet.$a/24 dev vbr0; done

# setup-host.sh's table, as it writes it
sed -n '/^table ip flk {$/,/^}$/p' "$src/setup-host.sh" |
  sed -e "s/\${subnet}/$subnet/g" -e "s/\${bridge}/$bridge/g" -e "s/\${uplink}/$uplink/g" >"$work/table.nft"
nft -f "$work/table.nft" || { bad "setup-host.sh's nft table doesn't load"; echo done; exit; }
ok "nft table loads"
helper="$work/flk-ports"
sed -e "s/@FLK_SUBNET@/$subnet/" -e "s/@FLK_MIN_PORT@/$min_port/" "$src/libexec/flk-ports" >"$helper"
chmod +x "$helper"

pids=""
for a in 10 11 12 13; do
  timeout 30 ruby -rsocket -e 's = TCPServer.new(ARGV[0], 7000); loop { c = s.accept; c.puts ARGV[0]; c.close }' \
    $subnet.$a </dev/null >/dev/null 2>&1 &
  pids="$pids $!"
done
# a host service on the VIP only, port 30000
timeout 30 ruby -rsocket -e 's = TCPServer.new(ARGV[0], 30000); loop { s.accept.close }' $vip </dev/null >/dev/null 2>&1 &
pids="$pids $!"
sleep 1

reach() { ruby -rsocket -e 'begin; s = Socket.tcp(ARGV[0], ARGV[1].to_i, connect_timeout: 1); print s.gets.to_s.strip; rescue; print "none"; end' "$1" "$2"; }
expect() { # ADDR PORT WANT
  local got; got=$(reach "$1" "$2")
  [[ $got == "$3" ]] && ok "$1:$2 -> $3" || bad "$1:$2 -> $got, want $3"
}
refuse() { # LABEL INPUT EXPECTED_ERROR
  local out
  if out=$(printf '%b' "$2" | "$helper" replace 2>&1); then bad "$1: accepted"
  elif [[ $out == *"$3"* ]]; then ok "$1: refused"
  else bad "$1: wrong error: $out"; fi
}

printf '%s\n' "tcp 25565 $subnet.10 7000 $vip" "tcp 25566 $subnet.11 7000" \
  "tcp 25567 $subnet.12 7000 $vip" "tcp 25567 $subnet.13 7000" | "$helper" replace ||
  bad "helper rejected a valid list"
expect $vip 25565 $subnet.10      # bound: answers on its address
expect $lan 25565 none            # ...and only there
expect $vip 25566 $subnet.11      # unbound: every address
expect $lan 25566 $subnet.11
expect $vip 25567 $subnet.12      # same port both ways: bound wins on its address
expect $lan 25567 $subnet.13      # ...the other takes the rest
"$helper" list | grep -q "$vip . tcp . 25565" && ok "list shows addr_ports" || bad "list lacks addr_ports"

refuse "listener on that address" "tcp 30000 $subnet.10 7000 $vip\n" "listening on tcp port 30000 ($vip)"
printf '%s\n' "tcp 30000 $subnet.10 7000 $lan" | "$helper" replace >/dev/null 2>&1 &&
  ok "same port on another address is fine" || bad "refused port 30000 on $lan (the listener is on $vip only)"
expect $lan 30000 $subnet.10
refuse "unbound port with a listener on any address" "tcp 30000 $subnet.10 7000\n" "listening on tcp port 30000"
refuse "loopback address" "tcp 25565 $subnet.10 7000 127.0.0.1\n" "bad host address"
refuse "machine address" "tcp 25565 $subnet.10 7000 $subnet.11\n" "bad host address"
refuse "not an address" "tcp 25565 $subnet.10 7000 10.47.11.300\n" "bad host address"
refuse "duplicate on an address" "tcp 25565 $subnet.10 7000 $vip\ntcp 25565 $subnet.11 7000 $vip\n" "listed twice"
refuse "below min_port" "tcp 80 $subnet.10 7000 $vip\n" "below 1024"
refuse "extra field" "tcp 25565 $subnet.10 7000 $vip x\n" "too many fields"

kill $pids 2>/dev/null
echo done
