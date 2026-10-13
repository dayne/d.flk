# lazyflk TODO

lazyflk's own backlog. What lazyflk needs from flk is in `../TODO.md`
("For lazyflk") and SPEC section 9; G1–G6 and G8–G10 are done, G7
(events) is later.

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
- [ ] M1.3 space checks, per-volume backup bytes in `disk --json`.
- [ ] M1.4 before_deploy backups, `releases rollback --with-volumes`.
- [ ] M1.5 `volumes move`.

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
