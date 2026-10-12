# Building lazyflk (for AI agents)

You're building lazyflk, a terminal UI for hosts running flk. It lives in
flk's repo as `lazyflk/`, its own Go module (flk itself is Ruby; don't add Go
to it). Read `SPEC.md` first; it's the source of truth for scope, principles, screens and
milestones. Work milestone by milestone (SPEC section 11) and keep each one
shippable.

Ground rules:

- **flk's CLI is the only interface** (SPEC section 3.1). Run `flk ... --json`;
  never read `~/.local/share/flk` or call firecracker, tmux or nft directly.
  If flk lacks something, it's a gap: check SPEC section 9 and propose the
  flk change instead of working around it.
- **Learn flk from flk:** `flk help --all` (full reference),
  `flk help --all --json` (the command table, ideal for the palette),
  `flk context --all`. flk's own source is the parent directory (see
  `../AGENTS.md`); flk gaps (SPEC section 9) are changes there, tested with
  `../tests/run.sh`.
- **Real data:** `fixtures/` has actual output from the reference host
  (flk 0.1.0). Build and test against it first (`--demo`), and add new
  fixtures by running the same commands, never by hand-editing state.
- **Don't touch real apps.** This host runs a real Minecraft server
  (`minecraft-flk`) with players' data. Read-only commands against it are
  fine; for anything that starts, stops, deploys or destroys, use test apps
  named `flkt-*` (create them from `../tests/apps/hello`) and clean them
  up with `flk apps destroy NAME --yes`.
- **Never run sudo.** Root steps are shown to the admin, not run.

Start with M0 (SPEC section 11): Go module, the flk client with a fake that
serves `fixtures/`, and `lazyflk --demo` rendering the main view.
