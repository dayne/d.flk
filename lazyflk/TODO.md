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

## From flk 1d428f4 (deploy batch), not used yet

All additive; lazyflk works with it as is (checked 2026-10-13).
- [ ] **Rollback:** a "roll back" action on the app (`flk releases
  rollback [vN]`, confirm), and `--no-rollback` in deploy's form.
- [ ] **Releases tab:** show `image` (rollback possible), `machines`, and
  failed releases (`status`, `failure`, `failed_at`); `rollback_of`.
- [ ] **Health checks:** a deploy can fail after its checks; the job
  output already shows why, but the Overview could show the app's
  `checks` (from `config show` machine_config).
- [ ] **Config warnings:** `config show` `warnings` (unknown keys, with
  did-you-mean) on the Config tab and in Needs attention.

- [ ] **Huge pages** (flk 553b1a3): show machine `huge_pages` ("2M")
  on the machine Overview; doctor's "huge pages: A of T free" already
  shows on Health.

## Known gaps

- [x] **Reboots and log rotation** pin a banner in the followed log
  (`x` dismisses); checked live with a restart.
- [ ] **Detaching from the console inside tmux** (`Ctrl-b Ctrl-b d`) is
  only checked by reading; the automated run could only send `Ctrl-b d`
  straight to the inner tmux. Try it once by hand.
