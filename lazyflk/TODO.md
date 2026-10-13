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

## Known gaps

- [ ] **Reboots and log rotation** show as highlighted lines in the log,
  not a banner pinned to the top (SPEC 5.2 asks for a banner).
- [ ] **Detaching from the console inside tmux** (`Ctrl-b Ctrl-b d`) is
  only checked by reading; the automated run could only send `Ctrl-b d`
  straight to the inner tmux. Try it once by hand.
