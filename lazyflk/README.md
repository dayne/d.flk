# lazyflk

A terminal UI for hosts running [flk](../). See `SPEC.md` for scope and
milestones, and `AGENTS.md` if you're an agent working on it.

    go build -o lazyflk ./cmd/lazyflk
    ./lazyflk --demo        # fixtures/, no flk calls
    ./lazyflk               # flk from --flk, $LAZYFLK_FLK or PATH

Flags: `--demo`, `--read-only`, `--refresh 5s` (0 loads once), `--flk PATH`.

Keys: `↑↓` move, `←→` fold, `tab`/`1`…`9` tabs, `pgup`/`pgdn` scroll a tab,
`l` follow logs (then `f` follow, `/` search, `n`/`N`, `w` wrap, `[ ]`
machine, `esc` back), `?` help for the current view, `q` quit.

Tests: `go test ./...`. Main view snapshots are in
`internal/ui/testdata/`; after an intended change to the screen, rewrite
them with `go test ./internal/ui -update` and review the diff.

Layout: `cmd/lazyflk/` (flags), `internal/flk/` (client, types, streams,
and the `Fake` runner that serves `fixtures/`), `internal/host/` (`df`, the
one non-flk command), `internal/ui/` (Bubble Tea views), `fixtures/` (real
flk output, embedded for `--demo`).
