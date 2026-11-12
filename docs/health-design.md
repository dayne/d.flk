# Health while running (design draft)

**Status: draft, 2026-11-11. A future effort, not scheduled.** Decided
with Dayne the same day: checks report and don't act; the MQTT bridge
waits until its purpose is clearer. M6 step 3
builds the check kinds that run at deploy (`exec`, `udp`/`a2s`,
`[deploy] preflight`); this is the part after that: who runs checks while
the apps run, what else it watches, and how lazyflk, gamebus and MQTT
read the results. Nothing here is built yet.

## The problem

Checks run only during a deploy. After that, `flk status` says a machine
is `started` (its Firecracker process is alive), not that the app inside
answers. A game server that hangs with its process up looks fine to flk,
lazyflk and gamebus (enshrouded #3). Today the game repos' own status
tools scrape logs to find out.

flk has no daemon: every command runs and exits. The boot service
(`flk-tmux.service`) and the exit hook start machines and handle a machine
whose process dies (`machine.exited`, `machine.gave_up`). Nothing runs on
a schedule except the games' cron backups.

## Proposal: `flk check`, then one host timer

Revised from "a `flk-health` daemon" after a closer look. Build it in
three steps; each is useful by itself.

1. **`flk check [APP | --all]`**: run the checks of each running
   machine once, now. Store the last result per machine and check
   (`machines/ID/checks.json`: `{NAME: {ok, at, since, detail}}`), and
   emit `check.failed` / `check.recovered` events only when a result
   changes. `flk status --json` shows the stored results with their age.
   This is the whole engine, and it's testable in the fast tests. A user
   or lazyflk can run it by hand.
2. **One timer per host**, installed by `setup-host.sh --install-service`
   next to the boot units: `flk check --all --due` every minute. `--due`
   runs only the checks whose `interval` (opt-in per check, e.g. `"5m"`)
   has passed. It's a oneshot, not a daemon: nothing to crash or leak,
   the same code path as step 1, and the same user and state as every
   other flk command. The cost is one Ruby start a minute.
3. **Host checks** in the same run (below), emitting `host.*` events on a
   change.

Why not the other runners:
- A systemd timer per app: N units to keep in step with app configs
  (launch, destroy, config changes, a rename), for no gain over one timer
  that reads every app's config.
- A long-running `flk-health` service: needed only for checks more often
  than once a minute, or for state held in memory. Neither applies.
  Keep the name and the M5 role (`flk host check` for keepalived) in
  mind; a oneshot serves that too.
- The guest checks itself through flk-agent: no use when the guest is
  wedged, which is the case that matters most. It also needs every guest
  rebooted onto a new agent, and it can't do host-side kinds (tcp from
  outside, a2s). Exec checks still run in the guest, but the host
  decides when.

### Decisions to make

- **Checks report; they don't act** (decided 2026-11-11). A failed interval check changes
  status and emits an event. It doesn't restart a machine. An opt-in
  `on_failure = "restart"` (after N failures in a row) can come later,
  once the reporting has run on the real apps for a while. Restarting a
  game server with players on it is not something to do by default.
- **The log check stays a boot fact.** It passed once this boot, so it
  stays passed. tcp, http, udp/a2s and exec run again each interval.
- **Grace after a start**: an interval check doesn't run until the
  machine has passed its deploy checks, or a set time after boot has
  passed for machines started without a deploy, so a slow game boot isn't
  a failure.
- **Who watches the watcher**: record the last run in `STATE`.
  `flk doctor` and `flk context` say when the timer isn't installed, or
  hasn't run in 5 minutes while apps have interval checks. Otherwise
  stale results look healthy.
- **Paused, stopped and on hold**: skip checks while a machine isn't
  meant to answer, such as during a backup with a stop, during a deploy,
  or while paused.

## What else it could watch

Each item is a check result or a `host.*` event on a change, never a new
kind of output. They're listed with the most useful first.

Per machine (exec through the agent, so only on guests with it):
- Volume and root disk fill (`df` in the guest). A full volume is the
  most likely way a game server dies quietly.
- Memory pressure in the guest (`/proc/meminfo`, OOM kills in the
  kernel log).
- A restart loop: several `machine.restarted` in a short time. flk
  already gives up after a limit (`machine.gave_up`), so this is an
  earlier warning.

Per host (what `flk doctor` knows today, run on a schedule):
- Free space where flk keeps images, volumes and backups.
- Backups: none succeeded within the schedule (with a margin), or the last
  copy off the disk failed. A silent cron failure is the risk now.
- The boot units and network (bridge, NAT) still in place after an OS
  update.
- Podman storage growth (`flk images prune` suggests itself).

Not in scope: CPU and network graphs, history, or alert routing. That
belongs to a monitoring tool. flk reports state and changes, and others
store, graph and notify.

## lazyflk

lazyflk reads; it never runs checks on a schedule. It's a UI that's
open only some of the time, so it can't be the runner. What it gets:
- A health mark per machine in the tree, from `checks` in
  `flk status --json` (its TODO already plans this, "Health while
  running").
- `check.failed` / `check.recovered` / `host.*` through the `events -f
  --json` stream it already follows, for Needs attention.
- A "Check now" key that runs `flk check APP`.
- The "runner not installed" or "stale" note from `flk context --json`
  (a next step with `kind`).

All of it is additive JSON, so record it in "For lazyflk" as usual.

## MQTT: outside flk core

flk core stays free of a broker. flk's integration surface is its event
log and JSON (`events -f --json`, `status --json`); whatever publishes
to MQTT reads those. Reasons:
- Every flk host would need a broker or a dead config option, and flk's
  install and tests would gain a network dependency.
- The broker on mud is itself a flk app (`mqtt-flk`). flk depending on
  one of its own apps to report its own health is circular: when flk is
  in trouble, the broker may be too.
- It already works this way: gamebus follows flk's events and publishes
  game status to MQTT and Discord.

Where the bridge lives:
- **gamebus, extended** to forward `check.*` and `host.*` events for its
  games. Cheap, and it fits the games now. But gamebus is about games,
  and it wouldn't cover `mqtt-flk` or `opencode-sandbox`.
- **A small separate bridge** (`flk-mqtt`, or a gamebus mode for every
  app): `events --all -f --json` to `HOST/flk/APP/...` topics, plus a
  retained per-machine health topic. This is better if Home Assistant or
  anything other than games should see flk's health. Its home is a
  separate repo, as with gamebus.
- Optional later, in flk: a generic `[host] notify = "CMD"` hook that
  runs a command with the event as JSON on stdin when a check changes.
  It needs no broker and covers ntfy, mail or `mosquitto_pub` from a
  script, without anything having to follow the stream. Add it only if a
  follower turns out to be a burden.

Deferred (2026-11-11) until its purpose is clearer. Leaning: flk emits; a separate bridge publishes. Start by
extending gamebus for the games, and split a generic bridge out when a
non-game consumer wants it.

## Order, when it's picked up

1. M6 step 3 (deploy time): `exec`, `udp`/`a2s`, `[deploy] preflight`.
2. `flk check` with `checks.json`, `status --json` `checks`, and the
   change events (`check.recovered` is new).
3. The host timer with `--due` and `interval`, plus the doctor and
   context notes for a stale or missing runner.
4. Host checks (`host.*` events).
5. lazyflk and gamebus pick them up, each in its own repo.
6. Maybe later: `on_failure = "restart"` and a `notify` hook.
