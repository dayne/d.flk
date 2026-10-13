package ui

import (
	"strings"

	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"
)

// Colors are the basic 16 so they follow the terminal's theme; bold and
// reverse carry meaning on their own under NO_COLOR.
var (
	styleTitle    = lipgloss.NewStyle().Bold(true)
	styleDim      = lipgloss.NewStyle().Foreground(lipgloss.BrightBlack)
	styleOK       = lipgloss.NewStyle().Foreground(lipgloss.Green)
	styleWarn     = lipgloss.NewStyle().Foreground(lipgloss.Yellow).Bold(true)
	styleBad      = lipgloss.NewStyle().Foreground(lipgloss.Red).Bold(true)
	styleSelected = lipgloss.NewStyle().Reverse(true)
	styleKey      = lipgloss.NewStyle().Bold(true)
	styleLabel    = lipgloss.NewStyle().Foreground(lipgloss.Cyan)
)

// fit truncates or pads a styled string to exactly w cells.
func fit(s string, w int) string {
	if w <= 0 {
		return ""
	}
	s = ansi.Truncate(s, w, "…")
	if n := ansi.StringWidth(s); n < w {
		s += strings.Repeat(" ", w-n)
	}
	return s
}

// rule draws a horizontal border of width w with an optional title.
func rule(title string, w int) string {
	if title == "" {
		return strings.Repeat("─", max(w, 0))
	}
	title = ansi.Truncate(" "+title+" ", max(w, 0), "… ")
	return title + strings.Repeat("─", max(w-ansi.StringWidth(title), 0))
}
