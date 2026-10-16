# M5: more than one host (design draft)

**Status: draft, 2026-10-16. Not ready to build.** Other big pieces are
still coming (Tailscale first), and they change the answers to the
transport, addressing and witness questions below. This draft sets what
should hold however those turn out: the safety rule, the seams, and the
order of work. Everything under "Open" is waiting on those decisions.
Nothing here is built yet.

## What it's for

The real workloads are a few long-lived, stateful apps on a home LAN
(game servers, an MQTT broker), each with one machine and one volume.
For them, "more than one host" means:

1. **Moving an app** to another host on purpose (maintenance, a new
   box), with its volume, release and config, and one command to come
   back.
2. **A standby that takes over** when the active host dies, with the
   data loss known ahead of time (the last sync) and **never** two
   copies of an app running at once.

Not goals: scheduling across N hosts, live migration, apps with more
than one machine spread over hosts, fly's regions, or replicated block
storage in the first version.

## Where flk stands (what M5 builds on)

- All state is per host, under `FLK_HOME` (`~/.local/share/flk`):
  `apps/APP/{app.json, secrets.json, images/, machines/, volumes/}`.
- **Every host uses the same machine network**: `172.30.0.0/24` on
  `flkbr0`, the same IPs and MACs in tap order (`Net`, `setup-host.sh`).
  That's fine while hosts don't talk to each other, and it's the first
  thing to change if machines on different hosts ever have to reach
  each other (routed subnets, Tailscale subnet routes).
- Forwarded ports answer on every local address (`fib daddr type
  local`), or only on the `bind` addresses. So an address that moves
  between hosts already works, as long as something adds it to the host
  that should answer.
- **Backups are already copied to another host**: `backup_copy_to =
  "user@host:/path"` (rsync over ssh, keys only, sparse, resumable). A
  standby with those copies has a restorable volume today, a manual one.
- **The boot service resumes every machine whose desired state is
  `started`** (`flk resume`), and the exit hook / restart policy boot
  machines again on their own. These are the paths that could start a
  second copy, and the fence has to cover them.
- Events (`events.jsonl`) record every lifecycle change; lazyflk follows
  them.

## The rule: one holder per app

Every start goes through one check: **this host may run app A only if it
holds A**. Holding means a placement record:

```json
// apps/APP/placement.json (absent = today's single-host behaviour)
{ "holder": "hostB", "epoch": 7, "since": "2026-10-16T12:00:00Z",
  "peers": ["hostA"], "group": "games" }
```

- `epoch` goes up by one on every change of holder. A host that comes
  back with an older epoch doesn't run the app. It becomes the standby,
  and its old volume is kept as a backup, never synced over or deleted.
- The check (`Placement.may_run?(app)`) sits in `VM.start`, under the
  lock, so `machine start`, `deploy`, `resume` at boot, restart-policy
  revives and the exit hook all pass through it. A refusal is an event
  (`placement.refused`) and a doctor warning, not a crash.
- **No placement record = no change.** Apps that don't opt in behave
  exactly as now. That keeps the PLAN rule: real apps run on main's
  `bin/flk`, and new behaviour has to be opt-in.

Who gets to change the holder is what makes a setup safe or not:

| Change of holder | Safe because | Data loss |
| --- | --- | --- |
| Planned move (`flk apps move`) | the old holder stops first and hands over with epoch+1, and both hosts are reachable | none (final sync of the stopped volume) |
| Operator takeover (`flk host activate --force`) | a person says the old holder is dead (or unplugged) | since the last sync/copy |
| Automatic takeover | **needs a witness**: a third party that grants the epoch (see Open) | since the last sync/copy |

With two hosts and no witness, automatic failover can't be made safe: a
network split looks the same as a dead peer from both sides. Keepalived
(VRRP) alone has this problem, since both sides become MASTER. So in
this design keepalived moves the **address**, while the **app** only
moves on a granted epoch.

## Seams (where Tailscale and other pieces plug in)

Keep each of these behind one small interface, so choosing Tailscale
(or not) means picking an implementation, not a redesign:

1. **Peer transport.** A peer is an ssh destination (`user@host`), as
   `backup_copy_to` is now. A tailnet name (`user@hostb`, MagicDNS) or
   Tailscale SSH works with no flk change. Everything host-to-host
   (sync, move, status) is `ssh PEER flk ... --json` plus rsync.
2. **Service address.** How clients find the active host. Backends:
   `none` (clients follow by DNS or by hand), `lan` (flk-net adds a
   floating LAN address with gratuitous ARP; VRRP/keepalived optional),
   later `tailscale` (a tailnet service address or MagicDNS name, which
   also works across sites, where VRRP can't). flk only calls
   `address.up(group)` / `address.down(group)`.
3. **Witness / epoch grant.** Who says "hostB now holds group games at
   epoch 8". Backends: `manual` (an operator with `--force`), later a
   third host over ssh (a NAS, a Pi: a file and `flock`), or a tailnet
   node. Until one exists, automatic takeover is off.
4. **Data path.** How the standby gets the volume: `copy` (M1's backup
   copies; RPO = backup interval), `sync` (`flk volumes sync` of a
   stopped volume, or of a backup taken with the app running), later
   block replication (DRBD, or snapshot shipping once volumes sit on a
   reflink filesystem).

## Order of work

Each phase is useful on its own and ends with tests.

### P0: host identity and peers (small, no behaviour change)

- A host id and name (`host.toml`: `name`, default the hostname; an id
  generated once into `FLK_HOME`).
- `peers = ["user@hostb"]` in `host.toml`; `flk host peers [--json]`
  checks each one (ssh in BatchMode, the peer's flk version and schema,
  its name and subnet). Doctor warns on an unreachable peer, or on a
  peer that uses the same machine subnet (only matters once machines
  route between hosts).
- Machine subnet per host: setup-host.sh already takes `FLK_SUBNET`;
  document picking a different one per host, and record it so flk can
  report it.

### P1: planned moves (the most value, the least risk)

- `flk volumes sync VOL --to PEER`: the machine is stopped (as for
  `volumes move`), rsync `--sparse --inplace` into the peer's volume
  dir, then e2fsck on the far side. A second sync only sends changed
  blocks. With the app running: sync the newest backup instead
  (`--from-backup`).
- `flk apps move APP --to PEER`: sync while running (from a fresh
  backup), stop, final sync, copy the current release's rootfs image,
  app.json and secrets.json (0600, over ssh), write placement on both
  sides (epoch+1, the peer is the holder), start there, check health. If
  the start fails there, the app moves back (epoch+1 again, the old host
  holds it) and starts on its old volume, which the move never touched.
- Events `app.moved`, `volume.synced`; `context --json` gets per app
  `placement: { holder, epoch, here }` (additive, null without a record).

### P2: managed extra addresses (TODO.md "LAN addresses and failover")

- flk-net adds/removes listed addresses (root-owned config,
  `ip addr add` + gratuitous ARP), doctor runs `arping -D`, and warns
  when an address is inside the DHCP pool.
- An address belongs to a group; `bind` in the apps' flk.toml (or the
  group) makes their ports answer only there.

### P3: takeover

- `flk host activate GROUP [--force]`: with a witness, ask for epoch+1;
  without one, only with `--force` (after "the old holder is down?").
  Then restore or attach the newest synced volume, bring the address up,
  and start the group's apps.
- `flk host deactivate GROUP`: stop the apps, address down, give up the
  epoch (a planned move does the same).
- `flk host check GROUP --json`: machines running, ports mapped, epoch
  held: for keepalived's `track_script` or any monitor.
- Self-fencing: a holder that can't reach the witness (or its peer and
  gateway, in two-host mode) for `fence_after` stops the group's apps
  before the standby is allowed to take over (`takeover_after >
  fence_after + kill_timeout`). This only protects you when the host is
  still running flk. A hung host needs the witness, or a watchdog.
- A sample keepalived.conf in `share/help/` that calls only
  activate/deactivate/check.

### Later

Block replication, Tailscale backends (once chosen), machines reaching
each other across hosts (`APP.internal` across hosts needs routed
subnets), more than two hosts.

## CLI and JSON (all additive)

| New | Output |
| --- | --- |
| `flk host peers [--json]` | `[{ peer, name, reachable, flk_version, schema, subnet }]` |
| `flk host status [--json]` | `{ name, id, groups: [{ group, held, epoch, address }] }` |
| `flk volumes sync VOL --to PEER [--from-backup ID]` | `Next:` line, event |
| `flk apps move APP --to PEER` | `Next:` line, events |
| `flk host activate\|deactivate GROUP`, `flk host check GROUP` | exit codes for keepalived |
| `context --json` per app | `placement` (null when absent) |
| events | `app.moved`, `volume.synced`, `placement.refused`, `host.activated`, `host.deactivated` |

lazyflk gets a note in its TODO.md when P1 lands, not before.

## Testing

- Fast tier: the placement check and the epoch rules (stale epoch,
  missing record, refusal on each start path) with a fake peer, no VMs.
- Two hosts on one box: a second `FLK_HOME`, a second bridge and subnet
  (`FLK_BRIDGE`/`FLK_SUBNET`), the peer reached as `ssh localhost` with
  `FLK_HOME` set. Covers sync and move end to end with `flkt-*` apps.
- A real second host for the address and takeover phases (host work,
  `~/mud`). Never with the real apps until a move round-trips on
  `flkt-*` apps.

## Open (decide after Tailscale)

1. **Transport:** plain ssh with keys, or Tailscale SSH / tailnet names?
   (The design works either way: a peer is an ssh destination.)
2. **Service address:** LAN floating IP + VRRP, a tailnet address, or
   both? A tailnet address also covers hosts that aren't on the same LAN.
3. **Witness:** a third host over ssh, a tailnet node, or manual only?
   This decides whether automatic takeover ships at all.
4. **Group membership:** declared in `host.toml` (`[groups.games] apps,
   address, peers`), or derived from the apps' `bind` address? Declared
   is clearer, and works for Tailscale addresses that no app binds.
5. **Where placement lives:** per app (`placement.json`, above) vs per
   group. Per app makes moving one app simple; groups make takeover one
   step. Possibly both: an app's record names its group.
6. **Machine networking across hosts:** distinct subnets per host now
   (cheap, doctor-checked), routed by Tailscale subnet routes later?
7. **Secrets in transit and at rest on the peer:** ssh is enough for
   transit; is a 0600 file on the standby acceptable?
8. **RPO the games can live with:** hourly backup copies, or a sync
   every few minutes from a backup taken with the app running?
