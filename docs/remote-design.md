# An app written here, run on another host (plan draft)

**Status: plan, 2026-11-25. Nothing is built.** Dayne set flk up on a
second machine, `nexus`, and wants to write a new game server
(`~/spaceengineers.m`, Space Engineers) on mud and run it on nexus,
which has the memory for it. This is flk's side of that: what to build
so deploying to another host over ssh is a flk command and not a script
in every app repo. It is the first built piece of M5
(`docs/m5-design.md`): its P0 (host identity and peers) plus the
transport that P1's moves need anyway.

The app's side is `~/spaceengineers.m/PLAN.md`, for another agent.

## The two hosts (looked at 2026-11-25, read-only)

| | mud | nexus |
|---|---|---|
| flk | 0.7.0 (main `5f4be9d`, not pushed yet) | 0.6.0 (`~/Projects/d.flk` at `d38257c`) |
| Memory, CPUs | 30G, 8 | 62G (57G available), 16 |
| flk's disk | 50G free on `/` | 193G free on `/home` |
| OS, engine | Ubuntu, podman | CachyOS (Arch), podman 6.2.0 |
| Login shell | bash | **fish** |
| LAN address | 10.47.11.3 | 10.47.11.85 (and a tailscale0 address) |
| Machine subnet | 172.30.0.0/24 | 172.30.0.0/24 (the same) |
| Apps | 8 | none; `flk doctor` says ready |
| Check timer | installed | `flk-check.timer` not found |

`ssh nexus` works from mud with a key, in BatchMode.

Three things this already shows:

- **The login shell can't be assumed.** `ssh nexus 'ls ~/*.flk'` failed
  in fish ("No matches for wildcard"). Whatever flk sends must not pass
  through the peer's shell as shell text.
- **Versions drift.** nexus is one release behind before any work has
  started. A command sent to a peer must know the peer's version.
- **Both hosts use the same machine subnet.** Harmless while machines on
  different hosts don't talk to each other (m5-design says the same).

## What works today, with no flk change

    rsync -a --delete --exclude .git ~/spaceengineers.m/ nexus:spaceengineers.m/
    ssh nexus "sh -c 'cd spaceengineers.m && flk launch'"
    ssh nexus "sh -c 'flk -a spaceengineers-flk status --json'"

That is what the app's agent starts with, in a `bin/se` wrapper. Every
flk command already runs without a terminal, takes `-a APP` from any
directory, and has `--json`, which is why this works at all.

What it costs, and so what flk should take over:

- every app repo writes the same rsync-and-ssh wrapper, with its own
  mistakes about quoting, the peer's shell and `PATH`;
- nothing records where a release on nexus came from (which host, which
  directory, which commit);
- the host-side hooks (`[deploy] preflight`, `[flk.backup] verify`) run
  where flk runs, so they need the repo's `bin/` on nexus too: the whole
  directory has to be synced, not just the Dockerfile's context;
- mud's tools (lazyflk, gamebus, `flk context --all`) can't see the app;
- a secret set from mud travels on a command line unless the wrapper is
  careful (`flk secrets set KEY=-` reads stdin; a wrapper has to know).

## What flk builds

In order. Each step is useful alone and changes nothing for an app or a
host that doesn't use it.

### R0: the hosts agree (no code; Dayne)

- Push main and `v0.7.0`; on nexus `git pull`.
- On nexus, once: `sudo ./setup-host.sh --install-service`, which adds
  `flk-check.timer` (health checks while running).
- Nothing else. The same subnet stays for now.

### R1: peers (M5's P0)

- `host.toml` in `FLK_HOME` (new): this host's `name` (default: the
  hostname) and an id made once.
- Peers by name:

      flk host peers add nexus dayne@nexus      # an ssh destination
      flk host peers [--json]                   # each one, checked
      flk host peers rm nexus

  The check is one ssh in BatchMode: reachable, the peer's flk path,
  version and JSON schema, its host name, machine subnet, free memory
  and disk. Output: `[{ name, dest, reachable, flk_version, schema,
  host, subnet, why }]`.
- `flk doctor` lists peers that don't answer or run another minor
  version (a warning, never a failure: a peer being off is normal).
- **How flk talks to a peer**, one small module (`Flk::Peer`), which
  everything below uses:
  - `ssh -o BatchMode=yes DEST -- sh -c '<one quoted line>'`, with the
    argv shell-escaped by flk, so a fish or zsh login shell only ever
    sees a single `sh -c` word;
  - flk's path on the peer is found once at `peers add` (`command -v
    flk` in a login shell, else `~/.local/bin/flk`) and stored, so a
    thin non-interactive `PATH` doesn't matter;
  - the transport command can be replaced (`FLK_SSH`), which is how the
    tests fake a peer.
- New on every host, so peers can be asked: `flk version --json`
  (`{ version, schema, host, id }`).

### R2: any command, on a peer

    flk -H nexus status
    flk -H nexus -a spaceengineers-flk logs -f
    flk -H nexus events --all -f --json
    FLK_HOST=nexus flk context --all

- `-H, --host PEER` (and `FLK_HOST`) is a global option like `-a`: flk
  runs the same command on the peer and passes stdout, stderr and the
  exit code through. With a terminal on stdin it asks ssh for one
  (`flk -H nexus console ID`, `flk -H nexus exec`); without, it behaves
  as flk does without a terminal.
- stdin goes through, so `flk -H nexus secrets set KEY=-` and `secrets
  import` keep a secret off both command lines.
- Before running, flk compares versions. A peer with an older minor
  version gets a warning on stderr; a command or option the peer's flk
  doesn't have fails there with that flk's own message.
- **Refused with `-H`:** `setup`, anything that needs root, `proxy`
  (it would listen on the wrong host; later), and commands that read
  local files other than the app directory (`volumes restore --from
  FILE`, `files cp` with a local side) until R4.
- The app is named by `-a`, or by `app =` in `./flk.toml` as now: in an
  app directory on mud, `flk -H nexus status` means that app on nexus.

This is the step that makes gamebus and lazyflk able to see nexus with
no new protocol: they already read `flk ... --json`.

### R3: deploy to a peer

    cd ~/spaceengineers.m
    flk -H nexus launch            # first time
    flk -H nexus deploy            # after that

For `launch`, `deploy` and `build` with `-H`:

1. Read and check `flk.toml` here first, so a mistake fails in a second
   and not after a sync.
2. Sync the app directory (the one holding `flk.toml`) to the peer:
   `FLK_HOME/src/APP/` there, with rsync over the same ssh. Everything
   goes except `.git` and what `.flkignore` lists (gitignore syntax),
   because hooks need the repo's scripts. **Open:** whether gitignored
   files go. `site.env` is gitignored on purpose and the hooks read it,
   so the default has to send it (0600 kept); `.flkignore` is for
   `logs/` and the like.
3. Run the command on the peer in that directory. The peer builds with
   its own podman, so images are native to it and nothing large crosses
   the network.
4. The release on the peer records its origin: `source: { host, path,
   commit, dirty }` (the commit and whether the tree had changes, when
   the directory is a git repo). `flk releases --json` shows it;
   `flk releases` adds "from mud".
5. flk here records which peer the app in this directory was last
   deployed to (`.flk/host` in the app directory? **Open**), so a bare
   `flk deploy` in a directory that deploys to nexus can refuse with
   "this app runs on nexus: flk -H nexus deploy" instead of quietly
   making a second copy on mud. This is the first, soft form of
   m5-design's rule, one holder per app.

Hooks (`preflight`, `verify`, `release_command`) run on the peer, in the
synced copy. That's right: they check the host the app runs on.

Later, not now: build here and send the image (`--build-here`), for a
peer without podman or a slow one. Nothing asks for it.

### R4: files across (as needed)

`flk -H nexus files cp` with a local side, `volumes restore --from` a
local file, `backups` copied back to mud (`backup_copy_to` already sends
them anywhere by rsync; mud as the destination of nexus's backups is
only configuration). Build when the app's agent asks for one.

### R5: the view from one host

`flk context --all --peers`, `flk apps list --peers --json` (each app
with its `host`), so lazyflk can show both hosts and gamebus can follow
both event streams. After R2 has been used for a while; the JSON is
additive (`host` on each app, null fields never removed).

### After that: M5 proper

P1 (planned moves: `volumes sync`, `apps move`) builds on R1 to R3 and
is unchanged. A machine subnet per host comes with it.

## Tests

- **Fast tier:** `Flk::Peer`'s quoting (arguments with spaces, quotes,
  `*`, `$`), the version comparison, the refusals, `.flkignore`, with
  `FLK_SSH` set to a script that runs the command locally under a second
  `FLK_HOME`.
- **VM tier, one box:** the same fake peer with a second `FLK_HOME`:
  `-H` launch, deploy, logs, secrets from stdin, the release's `source`,
  the bare-deploy refusal. `flkt-*` apps only.
- **Real peer:** a `flkt-*` app from mud to nexus and away again, once
  per step, by hand (`tests/run.sh --peer nexus`, skipped without it).
  The fish login shell on nexus is the real test of the quoting.

## Working with the app's agent

- It starts now, with the plain rsync-and-ssh wrapper. It doesn't wait
  for flk.
- What gets in its way goes into `~/spaceengineers.m/BUGS.flk.md`; this
  session reads it at the start, as with the other apps, and keeps the
  index in `TODO.md`.
- When R2 and R3 are on main and on nexus, its wrapper becomes `flk -H
  nexus ...`, and what the wrapper still has to do by itself is the list
  of what flk missed.
- On nexus it touches only its own app and `flkt-*` apps, never `sudo`.
  flk's own tests on nexus are this session's, by the same rule.

## Open (Dayne)

- **The option's name:** `-H nexus` / `FLK_HOST` (proposed), or a
  subcommand (`flk on nexus deploy`).
- **Where the synced source lives on the peer:** inside `FLK_HOME`
  (proposed: flk owns it, it goes when the app is destroyed), or in the
  home directory under the same name as here.
- **Is nexus always on?** If it's a desktop that sleeps or reboots into
  something else, the app's backups should copy to mud
  (`backup_copy_to`), and `flk host peers` being quiet about an absent
  peer matters more.
- **One version on both hosts:** by hand (`git pull` on each), or
  `flk -H nexus` warning is enough?
- **Order against machine snapshots** (`docs/snapshot-design.md`, on its
  own branch): this first (proposed, it unblocks the new game), or
  snapshots.
