package ui

import (
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"

	"lazyflk/fixtures"
	"lazyflk/internal/flk"
)

// at finds text on the screen (the nth occurrence, from 0), as a cell.
func at(t *testing.T, m *Model, text string, nth int) (int, int) {
	t.Helper()
	for y, line := range strings.Split(screen(m), "\n") {
		for from := 0; ; {
			i := strings.Index(line[from:], text)
			if i < 0 {
				break
			}
			if nth == 0 {
				return ansi.StringWidth(line[:from+i]), y
			}
			nth--
			from += i + len(text)
		}
	}
	t.Fatalf("%q not on screen:\n%s", text, screen(m))
	return 0, 0
}

func click(t *testing.T, m *Model, text string, nth int) {
	t.Helper()
	x, y := at(t, m, text, nth)
	send(m, tea.MouseClickMsg{X: x, Y: y, Button: tea.MouseLeft})
}

func wheel(t *testing.T, m *Model, text string, down bool) {
	t.Helper()
	x, y := at(t, m, text, 0)
	b := tea.MouseWheelUp
	if down {
		b = tea.MouseWheelDown
	}
	send(m, tea.MouseWheelMsg{X: x, Y: y, Button: b})
}

func TestMouseMain(t *testing.T) {
	m := demoModel(t, 100, 30)
	if m.View().MouseMode != tea.MouseModeCellMotion {
		t.Error("mouse is on by default")
	}
	sel := func() string { return m.nodes[m.cursor].key(m.apps) }

	click(t, m, "frosty-river-2714", 0) // a tree row
	if sel() != "machine/vintagestory-flk/f8f979ffff11cf" {
		t.Errorf("clicked to %s", sel())
	}
	click(t, m, "Record", 0) // a tab
	if m.tabName(m.nodes[m.cursor]) != "Record" {
		t.Errorf("tab %s", m.tabName(m.nodes[m.cursor]))
	}
	click(t, m, "minecraft-flk  1/1", 0)
	click(t, m, "minecraft-flk  1/1", 0) // clicking the selected app folds it
	if !m.collapsed["app/minecraft-flk"] {
		t.Error("second click should fold the app")
	}
	click(t, m, "vintagestory-flk  1/1", 0)
	wheel(t, m, "vintagestory-flk  1/1", true) // the wheel moves in the tree
	if sel() == "app/vintagestory-flk" {
		t.Error("wheel didn't move")
	}

	click(t, m, "enter actions", 0) // a footer key
	if m.menu == nil {
		t.Fatalf("footer click: no menu\n%s", screen(m))
	}
	click(t, m, "Host", 0) // outside the menu closes it
	if m.menu != nil {
		t.Error("click outside should close the menu")
	}
}

func TestMouseMenuAndConfirm(t *testing.T) {
	m := demoModel(t, 100, 30)
	goTo(m, kindMachine)
	press(m, "enter")
	click(t, m, "restart", 0)
	if m.confirm == nil {
		t.Fatalf("menu click: no confirm\n%s", screen(m))
	}
	click(t, m, "n esc cancel", 0)
	if m.confirm != nil || len(m.jobs) != 0 {
		t.Error("cancel by click")
	}
	press(m, "enter")
	click(t, m, "restart", 0)
	click(t, m, "y run", 0)
	if got := actionCalls(m); len(got) != 1 || !strings.Contains(got[0], "machine restart 225d58f615e7e6") {
		t.Errorf("ran %v", got)
	}
	wheel(t, m, "demo mode: flk was not run", false)
	click(t, m, "esc close", 0)
	if m.shown != nil {
		t.Error("esc by click")
	}
}

func TestMouseAttentionAndPalette(t *testing.T) {
	m := demoModel(t, 100, 30)
	withState(t, m, problems)
	click(t, m, "should be running but isn't", 0)
	if !m.attn || m.attnCursor != 1 {
		t.Fatalf("attention click: attn %v cursor %d", m.attn, m.attnCursor)
	}
	click(t, m, "should be running but isn't", 0) // again: run the fix
	if m.confirm == nil || !strings.Contains(screen(m), "flk -a minecraft-flk resume") {
		t.Errorf("fix by click:\n%s", screen(m))
	}
	press(m, "esc", ":")
	typeText(m, "version")
	click(t, m, "Print the flk version", 0) // no fields: runs
	if m.shown == nil || m.shown.line != "flk version" {
		t.Errorf("palette click: %+v", m.shown)
	}
}

func TestNoMouse(t *testing.T) {
	m := New(Options{Client: flk.New(flk.NewFake(fixtures.FS)), NoMouse: true})
	if m.View().MouseMode != tea.MouseModeNone {
		t.Error("--no-mouse")
	}
}
