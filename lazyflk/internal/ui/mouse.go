package ui

import (
	"strings"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

// Mouse support: the keys stay primary; a click does what moving there
// and pressing enter (or the key shown) would. Render records where
// things are drawn as zones; clicks and the wheel look them up there.

type zone struct {
	x0, x1, y int // cells [x0, x1) on row y
	click     func() tea.Cmd
	wheel     func(delta int) // rows: negative is up
}

// boxZone is a zone on a line of an overlay box's body, placed once the
// box's position is known.
type boxZone struct {
	line  int
	click func() tea.Cmd
}

func (m *Model) addZone(x0, x1, y int, click func() tea.Cmd) {
	m.zones = append(m.zones, zone{x0: x0, x1: x1, y: y, click: click})
}

// addWheel makes the rows [y0, y1) scroll with the wheel.
func (m *Model) addWheel(y0, y1 int, wheel func(delta int)) {
	for y := y0; y < y1; y++ {
		m.zones = append(m.zones, zone{x0: 0, x1: m.width, y: y, wheel: wheel})
	}
}

// keyFor turns a key hint as shown ("esc", "y", "n esc", "g/G") into the
// key it stands for; ok is false for hints that aren't one key (↑↓).
func keyFor(shown string) (tea.KeyPressMsg, bool) {
	for _, tok := range strings.Fields(shown) {
		tok, _, _ = strings.Cut(tok, "/")
		switch tok {
		case "esc":
			return tea.KeyPressMsg{Code: tea.KeyEscape}, true
		case "enter":
			return tea.KeyPressMsg{Code: tea.KeyEnter}, true
		case "tab":
			return tea.KeyPressMsg{Code: tea.KeyTab}, true
		case "space":
			return tea.KeyPressMsg{Code: tea.KeySpace, Text: " "}, true
		case "ctrl+c":
			return tea.KeyPressMsg{Code: 'c', Mod: tea.ModCtrl}, true
		}
		if r := []rune(tok); len(r) == 1 && !strings.ContainsRune("↑↓←→", r[0]) {
			return tea.KeyPressMsg{Code: r[0], Text: tok}, true
		}
	}
	return tea.KeyPressMsg{}, false
}

// hintZones makes each key hint of a footer clickable; the footer text
// starts at x on row y, laid out as keyHints does.
func (m *Model) hintZones(pairs []string, x, y, maxX int) {
	for i := 0; i+1 < len(pairs); i += 2 {
		w := ansi.StringWidth(pairs[i] + " " + pairs[i+1])
		if x+w > maxX {
			return
		}
		if k, ok := keyFor(pairs[i]); ok {
			m.addZone(x, x+w, y, func() tea.Cmd { return m.key(k) })
		}
		x += w + 2
	}
}

// mouse handles a click or the wheel.
func (m *Model) mouse(msg tea.MouseMsg) tea.Cmd {
	ms := msg.Mouse()
	find := func(wheel bool) *zone {
		for i := len(m.zones) - 1; i >= 0; i-- {
			z := &m.zones[i]
			if ms.Y == z.y && ms.X >= z.x0 && ms.X < z.x1 && (wheel == (z.wheel != nil)) {
				return z
			}
		}
		return nil
	}
	switch msg.(type) {
	case tea.MouseWheelMsg:
		delta := 0
		switch ms.Button {
		case tea.MouseWheelUp:
			delta = -3
		case tea.MouseWheelDown:
			delta = 3
		}
		if z := find(true); z != nil && delta != 0 {
			z.wheel(delta)
		}
	case tea.MouseClickMsg:
		if ms.Button != tea.MouseLeft {
			return nil
		}
		m.note = ""
		if z := find(false); z != nil {
			return z.click()
		}
		// a click outside a menu or the palette closes it, like esc
		switch {
		case m.menu != nil:
			m.menu = nil
		case m.palette != nil:
			m.palette = nil
		}
	}
	return nil
}

// overlayZones places an overlay box's zones: its body lines, and the
// hints in its footer.
func (m *Model) overlayZones(lines []string, footPairs []string) {
	if len(lines) == 0 {
		return
	}
	w := ansi.StringWidth(lines[0])
	x, y := max((m.width-w)/2, 0), max((m.height-len(lines))/2, 0)
	for _, b := range m.boxZones {
		m.addZone(x+2, x+w-2, y+1+b.line, b.click)
	}
	if footPairs != nil {
		m.hintZones(footPairs, x+2, y+len(lines)-2, x+w-2)
	}
}

// screenZones places a full-screen box's zones (job, command log, guides).
func (m *Model) screenZones(footPairs []string) {
	for _, b := range m.boxZones {
		m.addZone(2, m.width-2, 1+b.line, b.click)
	}
	if footPairs != nil {
		m.hintZones(footPairs, 2, m.height-2, m.width-2)
	}
}

// hints is keyHints for a box's footer, remembered so its keys can be
// clicked.
func (m *Model) hints(pairs ...string) string {
	m.footPairs = pairs
	return keyHints(pairs...)
}

func (m *Model) bodyZone(line int, click func() tea.Cmd) {
	m.boxZones = append(m.boxZones, boxZone{line: line, click: click})
}
