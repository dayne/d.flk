package ui

import (
	"fmt"
	"strings"
)

type helpKey struct{ keys, what string }

var mainHelp = struct {
	about string
	keys  []helpKey
}{
	about: "Everything flk runs on this host. Left: apps, with their machines (● running, " +
		"○ stopped, ! should run but doesn't), volumes (▢) and forwarded ports (⇄), " +
		"then the host. Right: tabs for the selection. Bottom: what needs attention, " +
		"from flk context --all. Below Host: Storage, Podman and Services, the rest of " +
		"what this host runs. Each tab shows the command that fills it, and every " +
		"action shows the command it runs before running it (L lists them all). " +
		"Changes show as they happen (flk events --follow); the Events tabs list them.",
	keys: []helpKey{
		{"↑ ↓  k j", "move in the tree"},
		{"← →", "fold or unfold an app"},
		{"tab  shift+tab", "next or previous tab"},
		{"1 … 9", "jump to a tab"},
		{"pgup pgdn", "scroll the tab (also ctrl+u ctrl+d)"},
		{"l", "follow logs: the machine, or all of the app's machines"},
		{"enter  x", "actions for the selection (start, stop, deploy, secrets, volumes…)"},
		{"s", "start or stop the selected machine"},
		{"c", "attach to the machine's console (detach: Ctrl-b d)"},
		{"!", "a shell inside the machine (flk ssh console; exit to come back)"},
		{">", "type a line into the machine's console, and watch its log answer"},
		{"d", "deploy the selected app"},
		{"a", "go through Needs attention; enter runs the fix flk suggests"},
		{"L", "command log: what lazyflk ran, with its output"},
		{":", "every flk command: find it, fill in a form, run it"},
		{"H", "flk's guides (flk help TOPIC): cheatsheet, operate, troubleshoot…"},
		{"?", "this help"},
		{"q  ctrl+c", "quit (asks first while a command runs)"},
		{"mouse", "click rows, tabs, entries and footer keys; the wheel scrolls (Shift selects text)"},
	},
}

var logsHelp = struct {
	about string
	keys  []helpKey
}{
	about: "Follows flk logs -f: the machine's console output, or every machine of the " +
		"app. Lines starting --- flk: are flk's own notes (boots, restarts); a " +
		"\"log rotated\" line means older output moved to console.log.1.",
	keys: []helpKey{
		{"f", "follow (stick to the newest line) on or off"},
		{"↑ ↓  k j", "scroll a line (scrolling up pauses following)"},
		{"pgup pgdn  space", "scroll a page"},
		{"g  G", "top, or bottom and follow"},
		{"/", "search (case-insensitive); enter jumps to the newest match"},
		{"n  N", "next or previous match"},
		{"w", "wrap long lines on or off"},
		{"[  ]", "previous or next machine (or all machines)"},
		{"x", "dismiss the banner (a reboot or log rotation seen while watching)"},
		{">", "type a line into this machine's console (its stdin); the answer shows here"},
		{"esc  q", "back to the main view"},
	},
}

var filesHelp = struct {
	about string
	keys  []helpKey
}{
	about: "A volume's files, or a backup's, through flk files (debugfs: no mount, no root). " +
		"On a running machine's volume it's what's on disk now; the guest may still have " +
		"newer writes in its cache. It only reads: changing files needs the machine " +
		"stopped (flk files cp/rm/mkdir/chown in a shell).",
	keys: []helpKey{
		{"↑ ↓  k j", "move"},
		{"enter  → l", "open a directory, or read a text file (up to 1M)"},
		{"← h  backspace", "up a directory (or back from a file)"},
		{"b", "next source: the live volume, then each backup, newest first"},
		{"c", "copy the selection (or the directory) out to this host"},
		{"r", "list again"},
		{"esc  q", "back to the main view"},
	},
}

func (m *Model) helpScreen() string {
	title, h := "Help ─ main view", mainHelp
	switch {
	case m.logs != nil:
		title, h = "Help ─ logs", logsHelp
	case m.files != nil:
		title, h = "Help ─ files", filesHelp
	}
	w := m.width - 4
	lines := wrap(h.about, w)
	lines = append(lines, "")
	for _, k := range h.keys {
		lines = append(lines, styleKey.Render(fit(k.keys, 18))+" "+k.what)
	}

	room := m.height - 4
	m.helpTop = max(min(m.helpTop, len(lines)-room), 0)
	foot := "any key closes this help · flk's guides: H · every command: :"
	if len(lines) > room {
		foot = "↑↓ scroll · any other key closes this help"
	}
	var b strings.Builder
	b.WriteString("┌" + rule(title, m.width-2) + "┐\n")
	for i := range room {
		s := ""
		if j := m.helpTop + i; j < len(lines) {
			s = lines[j]
		}
		if i == room-1 && m.helpTop+room < len(lines) {
			s = styleDim.Render(fmt.Sprintf("… %d more (↓)", len(lines)-m.helpTop-room+1))
		}
		b.WriteString("│ " + fit(s, w) + " │\n")
	}
	b.WriteString("├" + rule("", m.width-2) + "┤\n")
	b.WriteString("│ " + fit(styleDim.Render(foot), w) + " │\n")
	b.WriteString("└" + rule("", m.width-2) + "┘")
	return b.String()
}
