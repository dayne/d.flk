# lazyflk: a terminal UI for flk hosts

Status: spec, ready to build. Written 2026-10-12 alongside flk 0.1.0
(commit a51bf79). lazyflk lives in flk's repo as `lazyflk/`, a separate Go
module; flk itself stays Ruby and stdlib-only. Real outputs from the
reference host are in `fixtures/`.

## 1. Why

flk runs fly.io-style apps as Firecracker microVMs on one Linux host. Its CLI
explains itself well (`flk context`, `flk help cheatsheet`), but an admin
who touches the host once a month still has to remember which command to run
and in what order. lazyflk is for that admin: open it, see what is running
and what is wrong, and act, without remembering anything. It should be to
flk what lazydocker is to Docker or k9s is to Kubernetes.

No existing tool fits. Firecracker tools are CLIs (firectl) or web
dashboards bound to their own control planes (BandSox, firecrab). Container
TUIs (lazydocker, Dockmate, oxker) and k9s don't see microVMs. Cockpit
could host a web plugin, but a TUI works over plain SSH with nothing else
installed.

## 2. Who and what

**The admin:** comfortable in a terminal, works over SSH, remembers almost
nothing about flk between visits. Runs a handful of long-lived apps (game
servers such as Minecraft and Vintage Story, small web services), each with
a volume of precious data.

**They need to:**
1. See at a glance: which apps and machines exist, which run, which should
   run but don't, what's reachable where, and what needs attention.
2. Read logs, and type into an app's console (server commands: `say`, `stop`).
3. Start, stop, restart, deploy, resume, without looking anything up.
4. Understand problems: the host (KVM, network, boot service, disk), ports
   that are blocked, volumes that are missing.
5. Learn as they go: every action shows the flk command it runs.

## 3. Principles (non-negotiable)

1. **flk's CLI is the only API.** lazyflk runs `flk ... --json` and reads its
   output. It never reads or writes flk's state files
   (`~/.local/share/flk/...`), never calls firecracker, tmux, nft or podman
   for anything flk can answer. If lazyflk needs data flk doesn't give, the
   fix is a flk change (section 9), not a workaround. This keeps one source
   of truth and lets flk change its internals freely.
2. **Show the command.** Every action displays the exact command before it
   runs (`flk -a minecraft-flk machine stop 225d58f615e7e6`) and records it in
   a command log the admin can scroll and copy. The TUI teaches the CLI.
3. **Nothing to remember.** Every view shows its keys in a footer. `?`
   opens help for the current view. Each selected item has an action menu
   (`enter` or `x`) listing everything that can be done to it. A command
   palette (`:`) offers every flk command, built from `flk help --all --json`.
4. **Problems first.** The first screen leads with what needs attention
   (`next_steps` from `flk context --all --json`), each with a one-key fix
   where flk offers one.
5. **Safe by default.** Destructive actions (destroy app, destroy volume,
   `--delete-data`) need the name typed to confirm. A `--read-only` flag
   hides all actions. lazyflk never runs anything as root; root steps
   (`sudo .../setup-host.sh ...`) are shown as commands to copy.
6. **Never freeze.** All flk calls run in the background with a timeout; the
   UI stays responsive and shows "refreshing..." or the error. A slow or
   failing flk call degrades one panel, not the app.
7. **Works anywhere flk does:** 80x24 minimum, keyboard only (mouse
   optional), SSH, `NO_COLOR`, no root, no daemon.

## 4. Scope

**In (v1):** flk apps, machines, logs, consoles, releases, volumes, secrets
(names only), host ports, host health, and the flk-related parts of the host:
the `flk-net` / `flk-machines` systemd units, disk space where flk data and
volumes live, flk's container images.

**Later (v2+), "not just flk":** a provider model (section 10) so the same
UI shows the rest of what this admin looks after, in this order (chosen from
what the reference host actually runs; see section 10): storage, podman
containers and images, pinned systemd services, per-app actions.

**Out:** editing flk.toml in the TUI (open `$EDITOR` instead), multi-host
management, a web UI, metrics history and graphs.

## 5. Screens

### 5.1 Main view (opens here)

    ┌ lazyflk ─ host ready · LAN 10.47.11.116 · boot service ok ────────────────┐
    │ Apps                       │ minecraft-flk ─ Overview  Logs  Ports  Volumes │
    │ ▸ minecraft-flk  1/1 ●     │                                                │
    │   ● mellow-aurora-7882     │ release v5 (2 kept)        config ~/minecraft… │
    │   ▢ world 40GB (external)  │ machine 225d58f615e7e6 started  172.30.0.10   │
    │   ⇄ tcp/25565 udp/19132    │   cpus 4 · 11264MB · up 18m                   │
    │ ▸ vintage-story  0/1 ○ !   │ ports  tcp/25565 → 10.47.11.116:25565         │
    │                            │        udp/19132 → 10.47.11.116:19132         │
    │ Host                       │ volume world 40GB /data/minecraft/flk/world…  │
    │   health ✔  images 4       │                                                │
    ├ Needs attention ───────────┴────────────────────────────────────────────────┤
    │ ! vintage-story: machine 4f1e… should be running but isn't   [r] resume   │
    ├────────────────────────────────────────────────────────────────────────────┤
    │ ↑↓ move  enter actions  l logs  c console  s start/stop  d deploy  ? help  │
    └────────────────────────────────────────────────────────────────────────────┘

- **Left: tree.** Apps (expand to machines, volumes, ports), then Host.
  Icons: started `●`, stopped `○`, should-run-but-stopped `!`, external
  volume marked. Order: apps with problems first, then by name.
- **Right: detail tabs** for the selection. App: Overview, Logs, Ports,
  Volumes, Releases, Secrets, Config (`flk config show`, read-only). Machine:
  Overview, Logs, Record (`flk machine status`). Host: Health
  (`flk doctor --json`), Ports (all), Services, Disk, Images.
- **Bottom: Needs attention** (from `next_steps`), with a one-key fix when
  the step names a command lazyflk can run.
- **Footer:** keys for the current focus.

### 5.2 Logs

Follow mode for one machine or all machines of an app (`flk logs -i ID -f`
as a streamed subprocess). Keys: `f` toggle follow, `/` search, `n`/`N`
next/previous match, `w` wrap, `g`/`G` top/bottom, `[`/`]` previous/next
machine. Shows a banner when the log rotates (`console.log.1`) or the
machine reboots (`--- flk: booting ...` lines).

### 5.3 Console

- `c`: suspend the TUI, run `flk -a APP console ID` in the real terminal,
  restore on detach. Show the detach keys first (`Ctrl-b d`, or
  `Ctrl-b Ctrl-b d` inside tmux).
- `>`: "send a line" prompt. It types one line into the app's stdin
  without attaching and shows the following log lines inline (for example
  `say Restarting in 5 minutes`). Needs flk gap G3.

### 5.4 Actions

The action menu for the selection lists what applies, greyed out with a
reason when it doesn't ("start: already running"):

| Selection | Actions (flk command) |
|---|---|
| machine | start / stop / restart (`flk machine ...`), logs, console, send line, status record |
| app | deploy (`flk deploy`, run in the app's config dir: gap G2), scale, resume app (`flk -a APP resume`), stop-all app, secrets set/unset (`--stage` toggle), destroy (typed confirm) |
| volume | create (`--size`, `--path`, `--from-dir`), import, destroy (typed confirm; external: unregister vs `--delete-data`) |
| host | resume all, stop-all, ports sync, apps prune, doctor; root steps shown as copyable commands |

Long-running actions (deploy, stop-all, volume create `--from-dir`) stream
their output into a modal with a cancel key (SIGINT to flk), then refresh.

### 5.5 Command palette (`:`)

Fuzzy search over every command and subcommand in `flk help --all --json`.
Choosing one opens a form generated from its args and options (with the
option descriptions as help text). It shows the final command line, and
runs it on enter. `blocks` commands (console, proxy) explain what they do
first. This makes all of flk reachable even where the UI has no dedicated
screen.

### 5.6 Help

`?` shows the keys for the current view plus a short "what is this"
explanation. `H` opens a browser for flk's guides (`flk help cheatsheet`,
`install`, `first-app`, `operate`, `troubleshoot`, `uninstall`), so the
docs are one key away and always match the installed flk.

## 6. Data: which flk command feeds what

| Data | Command | When |
|---|---|---|
| Everything on the main view | `flk context --all --json` | start, after any action, on a live event; every 5s without events, every 30s with them |
| What happened (G7) | `flk events --all --json --follow` (`--since` on reconnect) | the whole session; Events tabs |
| Host health | `flk doctor --json` | Health tab open, after actions; at most every 30s |
| Disk space | `df --output=target,size,used,avail,pcent PATH...` for flk's state dir (`flk.state_dir`) and each volume's directory (`mount_dirs` in `context --all --json`) | every 30s |
| Ports (all apps) | `flk ports list --json` | Ports tabs |
| App detail | `flk -a APP context --json`, `status --json`, `releases --json`, `volumes list --json`, `secrets list --json` | when shown |
| Machine record | `flk -a APP machine status ID` | when shown |
| App config | `flk -a APP config show --json` (warnings, health checks; G2) | Config tab |
| Logs | `flk -a APP logs [-i ID] -n N [-f]` | Logs view (streamed) |
| Command table, guides | `flk help --all --json`, `flk help TOPIC` | start |

Rules: set `NO_COLOR=1` when running flk. Treat a non-zero exit as an error
and show stderr, which starts with `Error:` and usually ends with the fix.
Unknown JSON fields must be ignored, not fatal. Find flk via `$LAZYFLK_FLK`,
then `PATH`.

Measured on the reference host: `context --all --json` 0.35s, `doctor
--json` 0.36s, most others 0.08–0.15s. **But** listing commands can block for
as long as a deploy holds flk's lock (12.5s observed; gap G1): never call
flk on the UI thread.

## 7. Technology

- **Go**, with Bubble Tea, Bubbles and Lip Gloss (charmbracelet). That gives
  a single static binary and the same model as many current TUIs, and
  `teatest` covers snapshot testing. tview (k9s) is an acceptable
  alternative; pick one and stay with it.
- One `flk` client package: runs commands with a context timeout, decodes
  JSON into structs whose fields are optional, and has a fake implementation
  that serves `fixtures/` for tests and `--demo` mode.
- Layout, under `lazyflk/` in flk's repo with its own `go.mod`:
  `cmd/lazyflk/`, `internal/flk/` (client and types), `internal/ui/`
  (views), `internal/actions/` (the action table, which maps selection to
  command), `internal/providers/` (from M5), `fixtures/`. Build output is
  git-ignored. flk's Ruby code and `tests/run.sh` must not depend on Go.
- No config file in v1. Flags: `--read-only`, `--demo` (fixtures, no flk
  calls), `--refresh 5s`, `--flk PATH`.

## 8. Testing and acceptance

- Unit tests decode every fixture. Snapshot tests render the main view,
  logs, the action menu and the palette from fixtures at 80x24 and 160x48.
- A fake flk binary (a script that prints fixtures and records argv) checks
  that each action runs exactly the command it displays.
- Manual run against the real host, using only `flkt-*` test apps for
  actions (create them from `../tests/apps/hello` or `mcshadow`). **Never
  run actions against `minecraft-flk` or other real apps while testing.**

v1 is done when, starting from the main view and without leaving lazyflk,
an admin can:
1. Tell which machines are running, which should be but aren't, and where
   each app is reachable.
2. Read and follow an app's logs, search them, and attach to its console
   and come back.
3. Stop, start and restart a machine, and deploy an app, seeing the flk
   command each time.
4. Find and act on everything listed under "Needs attention".
5. Run any flk command through the palette.
6. Leave the UI responsive while a deploy is running in another terminal.

### Acceptance run (2026-10-13): v1 done

Run on the reference host against flk 6183c62 with lazyflk 0b15539 plus
the logs banner, 110x40 in tmux. Actions only on the test app
`flkt-lazyflk-v1` (mcshadow without its host port), destroyed afterwards;
minecraft-flk and vintagestory-flk were only looked at.

| # | Result | How |
|---|---|---|
| 1 | pass | Tree: `●` per running machine, live CPU/memory, ports with their bound address (`10.47.11.3: tcp/25565 udp/19132`); a stopped-but-meant-to-run machine showed `!` on it and its app. |
| 2 | pass | `l` followed the test machine's log, `/Done` found the server's ready line; `c` showed the detach keys, attached (flk's tmux status bar), `Ctrl-b d` came back to lazyflk. |
| 3 | pass | Stop (3s), start, restart (4s) and deploy (v1 to v2), each showing `$ flk -a flkt-lazyflk-v1 …` first and its output after. |
| 4 | pass | After "stop all", Needs attention showed flk's "should be running but isn't"; `a`, enter ran `flk -a flkt-lazyflk-v1 resume`, and the panel went back to "nothing needs attention". |
| 5 | pass | `:` "releases" filled `-a` from the selection and ran `flk -a flkt-lazyflk-v1 releases`. |
| 6 | pass | During a deploy with a 20s build in another tmux window, 26 key presses each showed on screen within 0.04s (median 0.04s), and the refresh picked up v3 by itself. |

Also seen live: restarting the machine from the other window pinned the
reboot banner in the followed log (SPEC 5.2), and `x` dismissed it.

## 9. What flk needs to add first (gaps)

These are flk changes, made in the parent directory (its `AGENTS.md` explains how; the
command table is `lib/flk/commands.rb`, tests `tests/run.sh`). Do G1–G3
before the matching lazyflk milestone.

| Gap | Why lazyflk needs it | Proposed flk change |
|---|---|---|
| **G1 reads can block on deploys** | Listing commands reap exited machines, and that waits for the global lock a deploy holds for its whole run (12.5s observed). | Reaping inside read commands takes the lock non-blocking and skips when it's busy; the deploy syncs ports itself. |
| **G2 app config dir unknown** | `deploy` and `config show` must run in the app's directory, and flk doesn't record where that is. | Record the config file path in `app.json` on launch/deploy; expose it as `config_path` in `status`/`context` JSON. |
| **G3 no non-interactive console input** | "Send line" (5.3) without attaching. Also useful to agents. | `flk console ID --send "TEXT"` (tmux send-keys under the hood), maybe with `--wait-log REGEX`. |
| G4 no live resource numbers | CPU and memory per machine on the Overview. | `flk machine stats [--json]` from the firecracker process (CPU %, RSS) plus `pid` in machine JSON. |
| G5 no quick context | Polling every 5s shouldn't run all the doctor checks (podman, sudo, systemctl). | `flk context --all --json --no-host` (skip doctor), plus a separate `doctor --json` at a slower cadence. |
| G6 JSON has no version | Detect a flk that's too old or too new. | A top-level `"schema": 1` in `context`/`help --all` JSON, and a documented compatibility rule. |
| G7 no events | Polling is fine for v1; events would make it instant. | `flk events [--all] [-f] [--since T] [--json]`, one line per change, fed by every flk process and the exit hook (flk c0a98f4). |
| G8 no disk breakdown | Show what flk uses (release images, rootfs copies, volumes, logs) when a disk fills. | `flk disk [--json]`: bytes per app and category, actual (sparse-aware) and apparent. |
| G9 no unit status | Host Services tab: is `flk-net` / `flk-machines` running or failed, not just installed. | Unit state (installed, enabled, active, since) in `doctor --json`, and a warn for a failed unit. |
| G10 no image list | Host Images tab: flk's container images, which are in use, which are orphans. | `flk images --json` (repo, tag, app, release, in_use, orphan, size). |
| G11 config warnings only in `config show` | Needs attention for a typo in flk.toml without running `config show` per app per poll. | `config_warnings` per app in `context` JSON, and each as an `optional:` next step (flk 78f2084, 821f84b). Also a step for a machine left on a failed release, whose fix is `flk releases rollback`. |

Also visible on the reference host: the Minecraft app runs its own restart
loop inside the image because flk has no restart policy (flk `TODO.md`).
When flk gains one, lazyflk shows it on the machine Overview.

## 10. Beyond flk: providers (v2+)

A **provider** interface: `List() []Item`, `Detail(item)`, `Actions(item)`,
`Logs(item)`. flk is the first provider. The next ones, in priority order.
The order comes from what the reference host runs (2026-10-12): `/` at 90%
(9.5G free) holding flk's state and podman's storage; LVM data disks
`/data/minecraft` (66%) and `/data/vintagestory` (50%, the next game server);
a stray `podman` test container (`mc-run-test`) left running; `mosquitto`
(snap), `ssh`, `chrony`; no Docker.

1. **Storage** (in v1 already, as the Host Disk tab; this provider extends
   it). Free space for `/`, flk's state dir, and every disk holding a
   volume, with a warning at 85% and an alarm at 95%. The breakdown of what
   flk uses there comes from flk (gap G8), not from walking its files.
   Commands: `df`, `lsblk --json`. Read-only; any cleanup goes through flk
   (`apps prune`) or is shown as a command to copy.
2. **Podman containers and images** (`podman ps -a --format json`,
   `podman images --format json`, logs via `podman logs -f`). Actions: stop,
   rm (typed confirm), image prune shown as a command. Flags containers
   that have been running a long time with a test-ish name or a `localhost/`
   image, and images not referenced by any flk release (`flk.local/*` are
   flk's: link them to their app instead).
3. **Pinned systemd services.** flk's own units first (`flk-net.service`,
   `flk-machines.service`: state, last start, `journalctl -u UNIT -f`), then
   services the admin pins: a pin list in `~/.config/lazyflk/pins`, seeded
   with what this host runs (`ssh`, `snap.mosquitto.mosquitto`, `chrony`).
   State and logs as the user (`systemctl show`, `journalctl` needs the
   `systemd-journal` or `adm` group; say so if it's missing). Restart and
   stop need root: shown as `sudo systemctl ...` to copy, never run.
4. **App actions:** a `.lazyflk.toml` next to an app's flk.toml declaring
   named actions, each just a command line with placeholders, e.g.
   `backup = "flk -a {app} machine stop {machine} && cp {volume.world} /backups/ && flk -a {app} machine start {machine}"`,
   `say = "flk -a {app} console {machine} --send 'say {input}'"`. This keeps
   game-specific knowledge (Minecraft, Vintage Story) in the app's repo, not
   in lazyflk. Needs G2 (the app's directory) and G3 (send).

Not planned: Docker (none on the reference host; the podman provider can
take `--engine docker` later), libvirt, Kubernetes.

The same principles hold: providers use their tools' CLIs, every action
shows its command, and nothing runs as root.

## 11. Milestones

All done (2026-10-13): M0 24af5a0, M1 a444a67, M2 d0cc8f5, M3 e3aec5e,
M4 065e0c6, M5 c31c05f (plus mouse support). Gaps G1–G11 landed
in flk (G7 events: c0a98f4). Open items: `TODO.md`.

1. **M0 skeleton:** client and types, fake flk serving `fixtures/`, `--demo`
   renders the main view from fixtures.
2. **M1 read-only browser:** tree, detail tabs, attention panel, logs view
   with follow and search, host health. Real flk with background refresh.
   Needs G1 (or tolerate the freezes via timeouts until it lands).
3. **M2 actions:** action menus, start/stop/restart, resume/stop-all,
   deploy (G2), secrets, volumes. Command log, typed confirms, `--read-only`.
4. **M3 console and palette:** attach and return, send line (G3), command
   palette with generated forms, guide browser.
5. **M4 host extras:** stats (G4), disk breakdown (G8); quick polling
   (G5), version check (G6).
6. **M5 providers:** in section 10's order: storage, podman, pinned
   systemd services, `.lazyflk.toml` actions.

## 12. Decisions (owner, 2026-10-12)

- **Home:** `lazyflk/` inside flk's repo, as its own Go module.
- **Root steps:** shown as commands to copy, never run (for now).
- **Beyond flk:** the priority order in section 10 (storage, podman,
  pinned systemd services, app actions), chosen from the reference host.
