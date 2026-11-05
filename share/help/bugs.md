# Reporting flk bugs from an app

An app's repo (or a tool built on flk) can keep the flk problems it runs
into in a `BUGS.flk.md` file of its own. flk's developers read every one
of them, keep an index in flk's `TODO.md`, and answer in the entry
itself. One format for all of them:

    # BUGS.flk.md: flk bugs and feature requests from APP

    **For flk's developers:** each entry is self-contained.

    **Workflow:** work through the entries under "Open". When you fix one,
    change its status line to `Status: fixed in <commit>: <one line>`, or
    `Status: won't fix: <why>`. This side then checks the fix and moves it
    to "Resolved" as a one-line summary. New entries go at the bottom of
    "Open" with the next number (next: #1).

    ## Open

    ## Resolved

**An entry** (`### #N Title`):
- **Symptom:** what you ran, what happened, what you expected; date, host
  and flk commit (`flk version`, `git -C {{SRC}} rev-parse --short HEAD`).
  Paste the exact error.
- **Cause:** if you looked: the file and line, and why. Say whether it's
  verified or suspected.
- **Suggested:** the fix you'd like, as flk would show it (command,
  option, JSON field). Keep CLI and JSON changes additive: other tools
  read them.
- **Test:** how to show it's fixed, on a test app (`flkt-*`), never on a
  real one.
- `Status:` one line: `open (verified ...)`, `request`, then flk's answer.

**What helps:** `flk context --json`, `flk events --json`,
`flk logs -i ID --no-tail`, a failed build's `Build log:` file, and
`flk doctor`. Don't paste secrets (`flk secrets list` shows names and
digests, never values).
