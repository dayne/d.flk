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
  there first, then write the handler in `lib/flk/cli/GROUP.rb`, one file
  per command group (`machines.rb`, `volumes.rb`, `backups.rb`...).
  Dispatch, option parsing and app lookup are in `lib/flk/cli.rb`. The
  long-form reference text is `share/guide.md`; guides by stage are
  `share/help/*.md` (add new ones to `Commands::TOPICS`). Commands that
  change things end with a `Next:` line (`next_step`).
- lazyflk, the terminal UI, is its own repo (github.com/dayne/d.lazyflk;
  `~/d.lazyflk` on the reference host). It uses only flk's CLI, so CLI and
  JSON changes are its API: keep them additive, and record what it needs
  in `TODO.md` ("For lazyflk").
- Tests: `tests/run.sh --fast` (no VMs, no root), and `tests/run.sh` for the
  full run. `./flk-sanity.sh` checks the host. Open issues are in `TODO.md`.

## Branch: smooth-install — reviewer notes (2026-10-15)

Six install-UX improvements for review and merge. All 53 fast tests pass
(`tests/run.sh 00-config 05-cli`). Changes are intentionally conservative:
no new commands, no new config keys, no JSON schema changes.

**Commits in order:**

1. `Docs: add git clone step, simplify step 3, fix 'Ubuntu/Debian' label`
   - `README.md`, `share/help/install.md`
   - Adds missing `git clone` as step 0 (the most-reported new-user gap).
   - Removes the redundant `mkdir`/`ln -s` before `flk setup --fix`; the
     `--fix` flag already creates `~/.local/bin/flk`. Users now run
     `{{SRC}}/bin/flk setup --fix` directly on first install.
   - Renames "Ubuntu/Debian one-offs" → "common podman fixes" (the
     registries fix is needed on Arch too).
   - README: collapses the 4-line manual registries workaround into the
     existing `flk setup --fix` line; adds `procps-ng` to Arch deps.
   - **Review focus:** does the new step 3 wording in install.md make the
     PATH situation clear enough? The note about `~/.local/bin` and new
     terminal is new.

2. `setup-host.sh: structured ✔ success summary with Next: hint`
   - `setup-host.sh` (last ~6 lines)
   - Replaces the single dense summary line with per-item ✔ checkmarks
     and a `Next:` line pointing to `flk setup --fix`.
   - Previously silent on success; new users had no feedback until they
     ran `flk-sanity.sh`.
   - **Review focus:** the `Next:` line says "log out/in if you were just
     added to kvm" unconditionally. Could be made conditional on whether
     usermod ran, but that needs a flag variable — is the current wording
     clear enough?

3. `doctor: print optional warnings after 'Ready to fly' line`
   - `lib/flk/cli/setup.rb` (`cmd_doctor`)
   - Partitions `warn` results from `pass`/`fail`. On a healthy host
     (`ok = true`), warnings now appear after "Ready to fly, locally."
     under an "Optional (won't stop VMs running):" header.
   - JSON output (`doctor --json`) is unchanged — warns remain in the
     `checks` array in their original position.
   - `flk-sanity.sh` reads `doctor --json`, so it is unaffected.
   - **Review focus:** when `ok = false` (there are failures), warnings
     print without a header after the "Fix the ✘ items above." line.
     Is that legible, or should the header appear in both cases?

4. `setup: preflight package check before downloading assets`
   - `lib/flk/cli/setup.rb` (`cmd_setup`, new `setup_preflight_packages!`)
   - Before the ~100MB firecracker/kernel download, checks for `tmux`,
     `mkfs.ext4`, `fakeroot`, and a container engine. Bails with a clear
     error pointing to `flk-sanity.sh --only packages`.
   - Ruby is already running (they launched `flk`), so it's not checked.
   - **Review focus:** should `curl` and `ip` also be checked here? They're
     in the packages list but less likely to cause a setup failure. Currently
     kept minimal to avoid false positives.
