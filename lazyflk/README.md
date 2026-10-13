# lazyflk

A terminal UI for hosts running [flk](../). See `SPEC.md` for scope and
milestones, and `AGENTS.md` if you're an agent working on it.

    go build -o lazyflk ./cmd/lazyflk
    ./lazyflk --demo        # fixtures/, no flk calls
    ./lazyflk               # flk from --flk, $LAZYFLK_FLK or PATH

Flags: `--demo` (actions say what they'd run, and run nothing),
`--read-only` (no actions), `--refresh 5s` (0 loads once), `--flk PATH`.

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

Tests: `go test ./...`. Main view snapshots are in
`internal/ui/testdata/`; after an intended change to the screen, rewrite
them with `go test ./internal/ui -update` and review the diff.

Layout: `cmd/lazyflk/` (flags), `internal/flk/` (client, types, streams,
and the `Fake` runner that serves `fixtures/`), `internal/actions/` (the
action table: selection → flk command, and fixes for `next_steps`),
`internal/host/` (`df`, the one non-flk command), `internal/ui/` (Bubble
Tea views), `fixtures/` (real flk output, embedded for `--demo`).
