# lazyflk TODO

lazyflk's own backlog. What lazyflk needs from flk is in `../TODO.md`
("For lazyflk") and SPEC section 9; G1–G11 are done.

## Future

- [x] **Mouse support (optional, the keys stay primary).** Done: on by
  default, `--no-mouse` to leave it to the terminal. The admin
  reached for the mouse; clicking should do the obvious thing:
  - click a tree row to select it, click an app's ▾/▸ to fold it
  - click a tab to open it; wheel scrolls the tree, the tab, logs, job
    output, guides and the palette list
  - click a menu item, a palette entry or a Needs attention entry to pick
    it (same as moving there and pressing enter: confirms still apply)
  - click the footer's key hints to press that key
  *Feasible:* Bubble Tea v2 reports clicks and the wheel with cell
  positions (`tea.View.MouseMode = tea.MouseModeCellMotion`, then
  `tea.MouseClickMsg` / `tea.MouseWheelMsg`). lazyflk draws plain
  strings, so it needs hit-testing: record each clickable region (row,
  tab, menu line, hint) with its screen rectangle while rendering, and
  look clicks up there. Test with the same fixtures by sending mouse
  messages at known cells.
  *Trade-off:* with mouse reporting on, the terminal's own text
  selection needs Shift (most terminals) or Option (macOS), and copying
  commands by selecting them is common. So: on by default with a
  `--no-mouse` flag, or off by default with `--mouse`; decide when
  building it.

## From flk 1d428f4 (deploy batch) and 553b1a3

Done; checked end to end on a test app (deploy --no-rollback failed, the
attention fix rolled it back).
- [x] **Rollback:** app menu `r` (kept, healthy releases; `--no-rollback`
  as "failing checks: leave it"), also in deploy's form.
- [x] **Releases tab:** failed (and why), current, kept, image pruned.
- [x] **Health checks** and **config warnings** lead the Config tab
  (`config show --json`); warnings are in Needs attention via G11.
- [x] A machine left on a failed release: Needs attention, fix = roll back.
- [x] **Huge pages** on the machine Overview's size line.
- [x] After a failed `--no-rollback` deploy, roll back goes to the current
  (last good) release (flk 3fd7177); the form offers it first and the
  attention fix runs `releases rollback vN`. Checked end to end.

## From flk M1 (backups you can trust)

- [x] M1.1 (4ff9e9b): volume menu `v` verify (one backup or all) and `a`
  restore as new (nothing stops); verify results and `restored_from`
  shown. Checked live on a test app.
- [x] M1.2 (a04fcc6): volume menu `c` copy (`--dest`, else
  backup_copy_to); copies (ok, or why not) under each backup; the
  doctor's copy check shows on Health and in Needs attention.
- [x] M1.3 (4b26b65): Disk tab lists backups per volume (size, count);
  the doctor's space estimate is on Health (a warn when tight goes to
  Needs attention); back up's confirm says what happens when short.
- [x] 1bdb910: destroy app asks keep/delete backups (`--with-backups`);
  host menu `B` prune backups of destroyed apps (typed confirm).
- [x] M1.4 (3f618a4): roll back's "volumes: back to then"
  (`--with-volumes`), checked against the before-deploy backups like flk
  does; before-deploy backups labelled in Backups, and on the release
  that took them. Checked live: the volume's data went back with v1.
- [x] M1.5 (63db57f, fbedbe7): volume menu `m` move (`--dir` or
  `--path`, machine stopped). Checked live, out and back into the state
  dir.

## From flk M2 (files in volumes)

- [x] ef6f865: volume menu `f` browse files: directories, text files (up
  to 1M; binary and bigger ones are copied out), the live volume or any
  backup (`b`), copy out (`c`, to the dir lazyflk started in). Read-only
  on purpose: writes need the machine stopped and stay on the command
  line. Checked live on a test app.
- [ ] Recapture fixtures on a quiet host (help-all.json gains `files`).

## From flk M3

- [x] G7 events (c0a98f4): one `flk events --all --json --follow` per
  session; a live event reloads the main view at once (and drops that
  app's cached tabs), so polling is a 30s backstop; reconnects with
  `--since`, dropping repeats; Events tabs on the host, apps, machines.
  Checked live: a machine stopped from the CLI showed within 1s.
- [x] exec (25b23ad): machine menu `e` run a command (`flk exec -i ID
  -- sh -c LINE`, output and exit status in the job view) and `h` shell
  (`flk ssh console`, the terminal handed over like the console; `!` on
  the main view). The palette puts exec's command after `--` and treats
  ssh console without -C/--send and exec --tty as interactive. Checked
  live.

## Polish (2026-10-13)

- [x] `{input}` takes any one line (apostrophes too): passed to sh as $1.
- [x] 80 columns: the detail pane wraps long lines (under a field's
  value; paths cut, not split at hyphens); short header; footers drop
  whole hints and keep `? help` and `esc`; tree ports drop the host's
  own address when narrow; port lines name the address once.

## Known gaps

- [x] **Reboots and log rotation** pin a banner in the followed log
  (`x` dismisses); checked live with a restart.
- [x] **Detaching from the console inside tmux** (`Ctrl-b Ctrl-b d`):
  checked through a real outer tmux client (2026-10-13): back in
  lazyflk, the outer tmux stays attached, the machine keeps running.
