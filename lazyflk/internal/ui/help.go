package ui

import "strings"

type helpKey struct{ keys, what string }

var mainHelp = struct {
	about string
	keys  []helpKey
}{
	about: "Everything flk runs on this host. Left: apps, with their machines (● running, " +
		"○ stopped, ! should run but doesn't), volumes (▢) and forwarded ports (⇄), " +
		"then the host. Right: tabs for the selection. Bottom: what needs attention, " +
		"from flk context --all. Each tab shows the flk command that fills it.",
	keys: []helpKey{
		{"↑ ↓  k j", "move in the tree"},
		{"← →", "fold or unfold an app"},
		{"tab  shift+tab", "next or previous tab"},
		{"1 … 9", "jump to a tab"},
		{"pgup pgdn", "scroll the tab (also ctrl+u ctrl+d)"},
		{"l", "follow logs: the machine, or all of the app's machines"},
		{"?", "this help"},
		{"q  ctrl+c", "quit"},
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
		{"esc  q", "back to the main view"},
	},
}

func (m *Model) helpScreen() string {
	title, h := "Help ─ main view", mainHelp
	if m.logs != nil {
		title, h = "Help ─ logs", logsHelp
	}
	w := m.width - 4
	lines := wrap(h.about, w)
	lines = append(lines, "")
	for _, k := range h.keys {
		lines = append(lines, styleKey.Render(fit(k.keys, 18))+" "+k.what)
	}

	var b strings.Builder
	b.WriteString("┌" + rule(title, m.width-2) + "┐\n")
	for i := range m.height - 4 {
		s := ""
		if i < len(lines) {
			s = lines[i]
		}
		b.WriteString("│ " + fit(s, w) + " │\n")
	}
	b.WriteString("├" + rule("", m.width-2) + "┤\n")
	b.WriteString("│ " + fit(styleDim.Render("any key closes this help · the full flk reference: flk help --all"), w) + " │\n")
	b.WriteString("└" + rule("", m.width-2) + "┘")
	return b.String()
}
