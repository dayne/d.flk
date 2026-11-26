# An app written on one host, run on another

flk runs an app on the host where you type `flk deploy`. With one line in
`flk.toml`, the app's directory can stay on the host where you work while
the app runs on another flk host, reached over ssh:

    [flk]
      host = "nexus"

From then on, in that directory:

    flk launch           # first time: sends the directory, registers and deploys there
    flk deploy           # sends the directory, then builds and deploys on nexus
    flk status           # every command about the app runs on nexus
    flk logs -f
    flk secrets set TOKEN=-  < token.txt
    flk volumes backup data

and from any other directory on this host, once it has been deployed:
`flk -a APP status`.

## What it needs

- `ssh nexus` works from this host with a key, no password prompt.
- flk on both hosts, the same version (`flk peers` shows both). The
  peer needs `flk` on its `PATH` or in `~/.local/bin` (`flk setup --fix`).
- `rsync` on both hosts.
- The name in `[flk] host` is **what the other host calls itself**: its
  hostname, or `name = "..."` in its `~/.config/flk/host.toml`. That is how
  the copy of `flk.toml` on that host knows it is at home. If ssh needs
  another address for it, map the name on this host:

      # ~/.config/flk/host.toml
      [peers]
        nexus = "dayne@10.47.11.85"

  `flk peers` asks each peer for its name and version.

The peer's login shell doesn't matter (bash, zsh, fish).

## Which host a command goes to

1. `-H HOST` (or `--on-host HOST`), for any command: `flk -H nexus doctor`,
   `flk -H nexus apps list`, `flk -H nexus context --all`.
2. else `FLK_HOST=HOST` in the environment, the same.
3. else `[flk] host` in this directory's `flk.toml`, for commands about the
   app. Commands about a host (`doctor`, `version`, `disk`, `images`,
   `apps`, `ports`, `resume`, `stop-all`) still act on this one.
4. else, with `-a APP` for an app that isn't on this host: the host it was
   last deployed to from here.

`-H local` (or `FLK_HOST=local`) means this host, whatever `flk.toml`
says. On the host named in `[flk] host` the key changes nothing.

`help`, `completion` and `flk peers` always run here. `setup`, `proxy` and
`flk ssh` can't be sent: they install, listen or mount on the host they
run on, so run them there (`ssh nexus`, then flk).

At a terminal flk says where a command went (`flk: on nexus`, on stderr).
Output, exit codes and `--json` are the peer's own. A command cut off here
(Ctrl-C on `flk logs -f`, a closed connection) is stopped there too.

Standard input reaches `secrets set KEY=-`, `secrets import` and `exec`.
For other commands flk leaves it alone, so `flk` in a shell loop doesn't
eat the loop's input.

## What a deploy sends

`flk launch`, `flk deploy` and `flk build` first copy the directory that
holds `flk.toml` to the peer, into `src/APP/` in its flk state dir
(`flk version --json` there prints `root`), then run there:

- **everything goes**, except `.git` and what `.flkignore` lists (one
  pattern per line, as in `.gitignore`). Hooks run on the peer
  (`[deploy] preflight`, `[flk.backup] verify` and `pre`/`post`), in that
  copy, so they need the repo's scripts and settings. A gitignored
  `site.env` is sent; add it to `.flkignore` if it must not leave this
  host;
- a file that is gone here is removed there; one that `.flkignore` names
  is left alone there (logs a hook writes, say);
- the build runs on the peer, with its container engine. Nothing is built
  here;
- the copy on the peer has a `.flk-origin` file saying where it is from.
  Edit here, not there: the next deploy replaces it.

Each release made this way records its origin. `flk releases` shows a
FROM column (`mud@1a2b3c4d5e6f+`: host, commit, `+` for uncommitted
changes); `--json` has `origin: { host, path, commit, dirty }`.

## On the peer itself

The app is an ordinary app there: `ssh nexus`, then `flk -a APP status`,
`flk context --all`, cron jobs for `flk volumes backup`. Its boot service
starts it after a reboot whether or not this host is up. Host paths in
hooks and in `host.toml` (`backup_dir`, `backup_copy_to`) are the peer's.

Hooks must run on the peer's system: keep them to `sh` or bash, and read
host settings from a file in the repo, never from this host's paths.

## Not yet

- Files across hosts: `flk files cp` with a local side and `flk volumes
  restore --from FILE` read the peer's filesystem, not this one. Copy the
  file over first (`scp`), or pipe through `flk exec`.
- One list of both hosts' apps (`flk apps list` shows this host; `flk -H
  nexus apps list` the other), and events from both in one stream.
- Moving an app and its volume from one host to another.
