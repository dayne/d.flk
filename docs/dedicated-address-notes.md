# A dedicated address for one machine (planning notes)

**Status: notes, 2026-11-15. Not scheduled, nothing built.** From the
review of enshrouded.flk BUGS #5. Dayne's decisions that day: the
root-owned allow-list is right; what gets forwarded in ("everything"?)
needs its security questions answered first; plan it with the later
network work (PLAN M5, managed extra addresses), not now. This file is
what that planning session should start from.

## The request

`[flk] own_address = "10.47.11.7"` (the report's name): give one host
address to one machine. Everything sent to the address goes to the
machine, and the machine's traffic leaves as that address (1:1 NAT).

Why: Enshrouded's game traffic is Steam networking on a random UDP port
the server picks at each start. Only the query port (15637) is fixed, so
`[[services.ports]]` can't list what to forward. A LAN player has been on
a Steam relay since 2026-11-13 (150-770ms, loss; 7-16ms before).

## What the review found

- Today's rules, as the report says: in, only `10.47.11.7 . udp . 15637`;
  out, masquerade, so the machine's traffic leaves as 10.47.11.3 (to the
  LAN, the route's src) or 10.47.11.111 (to the internet, the DHCP
  default route's src), never as .7.
- **The cause isn't proven.** The 9 direct sessions before Nov 13 ran
  under these same rules. What happened on Nov 13 at 06:25 was a restart
  of the machine: an unattended libc6 upgrade restarted flk-tmux.service
  and flk resumed it. No reboot (up since Oct 26), no network change. The
  game picked a new port and new NAT mappings; nothing else is known to
  differ. The player's PC firewall or a Steam setting remain possible.
- So: **test by hand before building** (below). The result also says how
  much has to be forwarded, which decides most of the security question.

## The test (Dayne, root; nothing in flk changes)

A temporary nft table next to flk's, so flk's own table isn't touched and
one command removes it. The syntax is checked (in a private network
namespace); the effect on real traffic isn't. Gone at a reboot.

    sudo nft -f - <<'EOF'
    table ip flktest {
      chain post {
        type nat hook postrouting priority srcnat - 1;
        ip saddr 172.30.0.16 oifname "enx44a92c50aed9" snat to 10.47.11.7
      }
    }
    EOF

Step 1 is that table alone (traffic out as .7). Have the LAN player
reconnect; watch `sudo tcpdump -ni flkbr0 'udp and host 172.30.0.16'`:
the player's LAN address means direct, 205.196.x / 162.254.x / 185.25.x
means a relay. If it's still a relay, add step 2, everything UDP in:

    sudo nft add chain ip flktest pre '{ type nat hook prerouting priority dstnat + 1; }'
    sudo nft add rule ip flktest pre ip daddr 10.47.11.7 meta l4proto udp dnat to 172.30.0.16

and try again. Connections made before a rule keep their old mapping, so
if a step changes nothing, restart the game once (`bin/en`, Dayne's
call) and try once more before deciding. Remove it all with
`sudo nft delete table ip flktest`.

What each result means:
- Direct after step 1: only the address on the way out matters. Build the
  `snat` half; listed ports stay as they are. No new exposure at all.
- Direct only after step 2: the open inbound side matters. The questions
  under "Forwarding in" need answers.
- Still a relay after both (and a restart): flk's NAT isn't the cause.
  Look at the player's side, or at the guest not knowing its own address
  (see "Other shapes"). The feature may still be worth having, but not
  for this.

## Agreed: root names the addresses

`flk-ports` runs as root with no password and is flk's safety boundary:
it refuses host ports under `FLK_MIN_PORT` and ports a host process
listens on. If flk.toml alone could claim an address, anything running as
the flk user could send all traffic for the host's main address, ssh
included, into a VM. So:

- `setup-host.sh` bakes a list of addresses that may be dedicated into
  the helper (as it does `FLK_MIN_PORT`); the helper refuses any other.
- flk.toml claims one from the list. flk refuses the host's `address`
  (host.toml), an address another app has as `bind`, and one that's
  already claimed.
- Open: should the root list say which app may claim each address
  (`ADDRESS=APP`)? Without it, any app the user deploys can take a listed
  address once its holder stops.

## Forwarding in: what "everything" means for security

To decide before building. Today every forwarded port is named in
flk.toml; this would be the first thing that opens ports nobody listed.

1. **Every port the guest listens on becomes reachable** from wherever
   the address is reachable: sshd, RCON, a database, a debug port bound
   to 0.0.0.0. Guests have no firewall of their own (`/flk/init` sets
   none). flk-agent is on vsock, not IP, so exec isn't exposed.
2. **Ports under `FLK_MIN_PORT`** (22, 80, 443) reach the guest. That
   limit protects host services; on a dedicated address root has already
   said the address isn't the host's.
3. **UPnP / NAT-PMP.** With masquerade, a guest that asks the router to
   open a port gets a mapping to an address nothing forwards. With its
   own address and everything forwarded, that mapping works: a guest (or
   a compromised game server) could open itself to the internet where the
   router allows UPnP. Check the router's setting; consider this the
   strongest reason for a narrower default.
4. **Host services on the address.** A daemon listening on all
   addresses (sshd) stops answering on the dedicated one while the
   machine runs, and answers there again when it stops. So a stopped
   machine shows the host's services on "its" address. Option: drop or
   reject traffic to a claimed address while its machine is down.
5. **Other apps' ports.** Ports forwarded on all addresses (`ports` map)
   would also answer on the dedicated address unless the dedicated rule
   comes before that map. Order to choose: the app's own listed ports
   (`addr_ports`), then the dedicated rule, then the any-address map.
6. **ICMP.** With all protocols, ping to the address is answered by the
   guest, so it stops showing that the host is up.
7. **Stray traffic.** Every packet to the address makes a conntrack
   entry toward the machine (scans, broadcasts): small, but new.

Narrower choices, from least exposure up:
- **Out only**: `snat`, plus the ports listed as today. Enough if step 1
  of the test works.
- **A protocol**: all UDP (what enshrouded needs), TCP stays listed.
- **Ranges**: `[[services.ports]] start_port`/`end_port` (fly.toml keys
  flk already knows and ignores), e.g. udp 1024-65535. Explicit and
  fly-shaped, and useful without a dedicated address too. As nft rules in
  a chain the helper refills, not map elements (interval maps with
  concatenated keys vary by nft version).
- **Everything**: the simplest to explain ("the address is the
  machine's"), the widest. If chosen, maybe with a deny list or
  `protocols = [...]`, and loud in `flk ports`, `flk context`, `config
  show` warnings and doctor.

## Traffic out as the address

- A `snat` rule for the machine's address ahead of the masquerade.
- A side effect worth having: today every machine's traffic leaves as
  the host, so LAN rules that trust the host's address (NFS exports, ssh
  allow-lists, router rules) also trust every VM. With its own address a
  machine can be told apart, and blocked from the LAN at the router.
- mud's default route uses the DHCP address (.111) as src. A machine
  leaving as .7 toward the internet relies on the router treating any
  address in the /24 alike.
- Only new connections get the new mapping. Applying it to a running
  machine needs either a restart or dropping its conntrack entries;
  decide which, and say so in the output.

## Other shapes of the same need

1:1 NAT may not be the best fix for Steam. Steam's direct connections
(ICE) trade address candidates, and a NATed guest only knows
172.30.0.16, which no LAN player can reach. The LAN player learns the
host-side address only when the server's packets reach it first.

- **A routed address**: the guest itself holds 10.47.11.7 (a /32 on its
  interface, its source for outbound); the host routes it to the bridge
  and answers ARP for it (proxy ARP) instead of owning it. No NAT, the
  game advertises a reachable address, LAN peers connect with no hole
  punching. Costs: a guest change (`/flk/init`, so a reboot or redeploy),
  the address leaves netplan, source-address handling in the guest. Same
  exposure as "everything".
- **A bridged tap**: the machine on the LAN with its own MAC. The most
  like a real server, the largest host change (the uplink in a bridge),
  and DHCP or a static address inside the guest.
- **A fixed game port**: none in this Enshrouded build; ask again when
  the game changes.

If the test fails after both steps, try the routed address by hand
before giving up on the idea.

## Fit with flk

- Config: a `[flk]` key (name open: `dedicated_address` reads better
  than `own_address`; fly calls theirs a dedicated IP). It should be the
  same object as M5's service address, so name and root-owned config
  come from "managed extra addresses" (TODO.md, LAN addresses and
  failover; `docs/m5-design.md` P2). flk-net adding the address itself
  (instead of netplan) belongs there too.
- One running machine per address, by the ports' owner rule; `flk scale
  count` above 1 with the key is an error or only the first machine.
- Where it shows: `flk ports` (and `--json`), `port.forwarded` /
  `port.dropped` events, `flk doctor` (address on the allow-list, on this
  host, not answered by another host), `flk context`, `config show`.
  All additive JSON; tell lazyflk.
- Rules: the helper refills them in the same nft transaction as the
  port maps, in chains of their own. New helper and chains mean a re-run
  of `setup-host.sh --install-service` (root), as `bind` needed; flk
  keeps working with an older helper and doctor says what's missing.
  Apps without the key see no change.
- Tests: `tests/cases/06-ports-netns.sh` already runs the helper and
  table for real in a private network namespace (no root); the in, out,
  allow-list and refusal cases fit there. A VM case for a guest reached
  on an unlisted port.

## Found on the way (host work, `~/mud`)

Every libc update restarts all the VMs through needrestart: the game
servers went down and came back at 06:25 on Nov 13, and flk resumed them
as designed (mud #6). Whether needrestart should leave
`flk-tmux.service` alone is a host setting.
