package ui

import (
	"strings"

	"github.com/charmbracelet/x/ansi"
)

// box draws a bordered panel w cells wide: title in the top border, body,
// then a footer below a divider when footer isn't empty.
func box(title string, body []string, footer string, w int) []string {
	out := []string{"┌" + rule(title, w-2) + "┐"}
	for _, l := range body {
		out = append(out, "│ "+fit(l, w-4)+" │")
	}
	if footer != "" {
		out = append(out, "├"+rule("", w-2)+"┤", "│ "+fit(footer, w-4)+" │")
	}
	return append(out, "└"+rule("", w-2)+"┘")
}

// overlay draws lines over the screen s, centered.
func overlay(s string, lines []string, width, height int) string {
	rows := strings.Split(s, "\n")
	if len(lines) == 0 {
		return s
	}
	w := ansi.StringWidth(lines[0])
	x, y := max((width-w)/2, 0), max((height-len(lines))/2, 0)
	for i, l := range lines {
		if y+i >= len(rows) {
			break
		}
		row := rows[y+i]
		rows[y+i] = ansi.Truncate(row, x, "") + "\x1b[m" + l + "\x1b[m" + ansi.TruncateLeft(row, x+w, "")
	}
	return strings.Join(rows, "\n")
}

// wrapKeep wraps plain text to w cells, breaking long words and keeping
// leading spaces (command output, where indentation matters).
func wrapKeep(s string, w int) []string {
	if w <= 0 {
		return []string{""}
	}
	return strings.Split(ansi.Hardwrap(s, w, true), "\n")
}
