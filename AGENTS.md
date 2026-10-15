# Working with flk (for AI agents)

flk runs fly.io-style apps as local Firecracker microVMs. Its CLI explains
itself, so ask it instead of guessing:

1. `flk context` (or `flk context --json`): host health, the app in the
   current directory, its machines, volumes and ports, plus the next steps
   that apply right now.
2. `flk help --all`: the full reference. Concepts, every command and option,
   the flk.toml subset, workflows, gotchas, exit codes. `--json` prints the
   command table.
3. `flk help COMMAND` (or `flk COMMAND --help`) for a single command.
4. `flk context --all` for every app on the host; `flk help troubleshoot`
   maps symptoms to commands; `flk help cheatsheet` is one screen by task.

Things to know:

- No flk command waits on a missing terminal: `flk logs` prints and exits,
  `flk apps destroy` needs `--yes`, and `flk console` refuses to attach (use
  `flk console ID --send TEXT --wait-log REGEX` to talk to the app, and
  `flk logs`). `flk proxy` blocks by design and is rarely needed, because
  machine IPs are reachable from the host.
- Listing commands take `--json`. Unknown options and extra arguments are
  errors, never silently ignored.
- `flk launch` reads `flk.toml` from the current directory; after that,
  `flk -a APP deploy` works from anywhere (flk records the config path).
- Only `sudo ./setup-host.sh` needs root. Don't run it unless `flk context`
  or `flk doctor` says to, and ask the user first.

Working on flk itself:

- Commands are defined in `lib/flk/commands.rb`. The CLI parses arguments
  and generates all help from that table, so add new commands and options
  there first, then write the handler in `lib/flk/cli.rb`. The long-form
  reference text is `share/guide.md`; guides by stage are `share/help/*.md`
  (add new ones to `Commands::TOPICS`). Commands that change things end with
  a `Next:` line (`next_step`).
- lazyflk, the terminal UI, is its own repo (github.com/dayne/d.lazyflk;
  `~/d.lazyflk` on the reference host). It uses only flk's CLI, so CLI and
  JSON changes are its API: keep them additive, and record what it needs
  in `TODO.md` ("For lazyflk").
- Tests: `tests/run.sh --fast` (no VMs, no root), and `tests/run.sh` for the
  full run. `./flk-sanity.sh` checks the host. Open issues are in `TODO.md`.
