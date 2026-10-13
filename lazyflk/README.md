# lazyflk

A terminal UI for hosts running [flk](../). See `SPEC.md` for scope and
milestones, and `AGENTS.md` if you're an agent working on it.

    go build -o lazyflk ./cmd/lazyflk
    ./lazyflk --demo        # fixtures/, no flk calls
    ./lazyflk               # flk from --flk, $LAZYFLK_FLK or PATH

Flags: `--demo` (actions say what they'd run, and run nothing),
`--read-only` (no actions), `--no-mouse` (leave the mouse to the
terminal), `--refresh 5s` (0 loads once), `--flk PATH`.

Mouse: click a tree row, a tab, a menu or palette entry, a Needs attention
entry (again to run its fix) or a footer key; the wheel scrolls what's
under it. Clicking the selected app folds it. With the mouse on, select
text with Shift held (Option on macOS), or start with `--no-mouse`.

Keys: `↑↓` move, `←→` fold, `tab`/`1`…`9` tabs, `pgup`/`pgdn` scroll a tab,
`l` follow logs (then `f` follow, `/` search, `n`/`N`, `w` wrap, `[ ]`
machine, `esc` back), `?` help for the current view, `q` quit.

Actions: `enter` or `x` opens the selection's actions; `s` starts or stops
a machine, `d` deploys an app, `a` goes through Needs attention (`enter`
runs the fix flk names). Each action shows its flk command first, asks
before anything disruptive, and wants the name typed before destroying
data. Output streams into a full-screen view (`ctrl+c` interrupts, `esc`
hides it while it runs); `L` is the log of everything run. Secret values go
to flk on stdin (`secrets set NAME=-`), so they never appear on screen or
in the log. Root steps (`sudo ...`) are only ever copied (OSC 52), never run.

Console: `c` attaches to a machine's console in your terminal (detach with
`Ctrl-b d`, or `Ctrl-b Ctrl-b d` inside tmux) and comes back; `>` types one
line into it (`flk console ID --send`) and shows the answer in the followed
log. `:` is every flk command from `flk help --all --json`, with a form
built from its args and options. `H` browses flk's guides (`flk help
TOPIC`).

Host: the Health, Services (flk-net / flk-machines units), Ports, Disk
(`df` plus `flk disk`: what flk uses per app, and backups) and Images
(`flk images`) tabs. Machines show live CPU, memory and uptime (`flk
machine stats`). With a flk that has them (schema 1), polling uses `flk
context --all --json --no-host` and takes host health from `flk doctor
--json` every 30s; an older flk still works, with the full context each
time and those tabs saying what's missing.

Beyond flk (SPEC 10), sections below Host:
- **Storage**: each filesystem holding flk's data and backups, its devices
  (`lsblk`: disk, partition, LVM volume), LVM snapshots, and room left in
  the volume group (growing is a `sudo lvextend` to copy).
- **Podman**: containers (including build containers an interrupted build
  left behind, with `podman rm --storage` behind a typed confirm),
  long-running test containers, and images that aren't flk's.
- **Services**: flk's units, then pinned ones from `~/.config/lazyflk/pins`
  (one unit per line; default `ssh`, `snap.mosquitto.mosquitto`,
  `chrony`). `l` follows `journalctl -u UNIT -f`; restart/stop/start
  are `sudo systemctl ...` to copy.

App actions: a `.lazyflk.toml` next to an app's `flk.toml` adds the app's
own commands to its menu (and its machines'):

    [actions]
    save = "flk -a {app} console {machine} --send save-all --wait-log 'Saved the game'"

    [actions.say]
    run  = "flk -a {app} console {machine} --send 'say {input}'"
    help = "broadcast a message to the players"

Placeholders: `{app}`, `{machine}`, `{machine.name}`, `{volume.NAME}` (its
file), `{dir}`, `{input}` (asked for: one line of any text). It runs with
`sh -c` in the app's directory, after showing the expanded command and
asking. The typed text is passed to sh as `$1` and `{input}` becomes
`"$1"` (quoted to fit where it stands), so quotes, `$` and the like
arrive as text and never run.

Tests: `go test ./...`. Main view snapshots are in
`internal/ui/testdata/`; after an intended change to the screen, rewrite
them with `go test ./internal/ui -update` and review the diff.

Layout: `cmd/lazyflk/` (flags), `internal/flk/` (client, types, streams,
and the `Fake` runner that serves `fixtures/`), `internal/actions/` (the
action table: selection → flk command, and fixes for `next_steps`),
`internal/host/` (`df`), `internal/providers/` (storage, podman,
services, app actions), `internal/ui/` (Bubble Tea views), `fixtures/`
(real output, embedded for `--demo`; `fixtures/capture.sh` recaptures).
