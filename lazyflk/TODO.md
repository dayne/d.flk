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

## Known gaps

- [x] **Reboots and log rotation** pin a banner in the followed log
  (`x` dismisses); checked live with a restart.
- [ ] **Detaching from the console inside tmux** (`Ctrl-b Ctrl-b d`) is
  only checked by reading; the automated run could only send `Ctrl-b d`
  straight to the inner tmux. Try it once by hand.
