package ui

import (
	"context"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"

	"lazyflk/fixtures"
	"lazyflk/internal/flk"
)

var update = flag.Bool("update", false, "rewrite testdata/*.golden")

// demoModel is the --demo model after its first load, sized w x h.
func demoModel(t *testing.T, w, h int) *Model {
	t.Helper()
	m := New(Options{Client: flk.New(flk.NewFake(fixtures.FS)), Demo: true})
	m.Update(tea.WindowSizeMsg{Width: w, Height: h})
	m.Update(m.Init()()) // no refresh: Init is just the load
	return m
}

func key(s string) tea.KeyPressMsg {
	switch s {
	case "up":
		return tea.KeyPressMsg{Code: tea.KeyUp}
	case "down":
		return tea.KeyPressMsg{Code: tea.KeyDown}
	case "left":
		return tea.KeyPressMsg{Code: tea.KeyLeft}
	case "right":
		return tea.KeyPressMsg{Code: tea.KeyRight}
	}
	return tea.KeyPressMsg{Code: rune(s[0]), Text: s}
}

// golden compares a rendered screen (styles stripped) with testdata/NAME.golden.
func golden(t *testing.T, name, screen string) {
	t.Helper()
	got := ansi.Strip(screen) + "\n"
	path := filepath.Join("testdata", name+".golden")
	if *update {
		os.MkdirAll("testdata", 0o755)
		os.WriteFile(path, []byte(got), 0o644)
	}
	want, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("%v (run go test ./internal/ui -update)", err)
	}
	if got != string(want) {
		t.Errorf("%s differs from %s:\n%s", name, path, got)
	}
}

// Every line is exactly as wide as the terminal, and there are as many as it is tall.
func checkSize(t *testing.T, screen string, w, h int) {
	t.Helper()
	lines := strings.Split(screen, "\n")
	if len(lines) != h {
		t.Errorf("%d lines, want %d", len(lines), h)
	}
	for i, l := range lines {
		if n := ansi.StringWidth(l); n != w {
			t.Errorf("line %d is %d wide, want %d: %q", i, n, w, ansi.Strip(l))
		}
	}
}

func TestMainViewSnapshots(t *testing.T) {
	for _, sz := range [][2]int{{80, 24}, {160, 48}} {
		w, h := sz[0], sz[1]
		t.Run(fmt.Sprintf("%dx%d", w, h), func(t *testing.T) {
			m := demoModel(t, w, h)
			screens := map[string]string{"app": m.Render()}
			m.Update(key("down"))
			screens["machine"] = m.Render()
			m.Update(key("down"))
			screens["volume"] = m.Render()
			m.Update(key("down"))
			screens["ports"] = m.Render()
			m.Update(key("down"))
			screens["host"] = m.Render()
			for name, s := range screens {
				checkSize(t, s, w, h)
				golden(t, fmt.Sprintf("main-%s-%dx%d", name, w, h), s)
			}
		})
	}
}

func TestNavigation(t *testing.T) {
	m := demoModel(t, 80, 24)
	sel := func() string { return m.nodes[m.cursor].key(m.apps) }
	if sel() != "app/minecraft-flk" {
		t.Fatalf("starts on %s", sel())
	}
	m.Update(key("up"))
	if sel() != "app/minecraft-flk" {
		t.Errorf("up from the top moved to %s", sel())
	}
	for range 10 {
		m.Update(key("j"))
	}
	if sel() != "host" {
		t.Errorf("bottom is %s", sel())
	}
	m.Update(key("k"))
	if sel() != "ports/minecraft-flk" {
		t.Errorf("above host is %s", sel())
	}
	m.Update(key("left")) // collapse from a child selects the app
	if sel() != "app/minecraft-flk" || len(m.nodes) != 5 {
		t.Errorf("collapsed: on %s, %d nodes", sel(), len(m.nodes))
	}
	if !strings.Contains(m.Render(), "▸ minecraft-flk") {
		t.Error("collapsed app should show ▸")
	}
	m.Update(key("right"))
	m.Update(key("down"))
	if sel() != "machine/minecraft-flk/225d58f615e7e6" {
		t.Errorf("expanded: on %s", sel())
	}
	// a refresh keeps the selection
	hc, _ := m.opt.Client.HostContext(context.Background())
	m.Update(contextMsg{hc: hc})
	if sel() != "machine/minecraft-flk/225d58f615e7e6" {
		t.Errorf("after refresh: on %s", sel())
	}
	if _, cmd := m.Update(key("q")); cmd == nil {
		t.Error("q should quit")
	}
}

// A failing flk shows its error in place of the data, then alongside stale data.
func TestFlkErrors(t *testing.T) {
	m := New(Options{Client: flk.New(flk.NewFake(os.DirFS(t.TempDir())))})
	m.Update(tea.WindowSizeMsg{Width: 80, Height: 24})
	m.Update(m.Init()())
	s := ansi.Strip(m.Render())
	checkSize(t, m.Render(), 80, 24)
	for _, want := range []string{"flk error", "flk failed", "$ flk context --all --json", "Error: demo mode has no captured"} {
		if !strings.Contains(s, want) {
			t.Errorf("missing %q in:\n%s", want, s)
		}
	}

	m = demoModel(t, 80, 24)
	m.Update(contextMsg{err: fmt.Errorf("Error: timed out\nsecond line")})
	s = ansi.Strip(m.Render())
	if !strings.Contains(s, "✘ refresh failed: Error: timed out") || !strings.Contains(s, "mellow-aurora-7882") {
		t.Errorf("stale data with error:\n%s", s)
	}
}

func TestRestartText(t *testing.T) {
	for _, c := range []struct {
		r    flk.Restart
		n    *flk.Restarts
		want string
	}{
		{flk.Restart{Policy: "on-failure", Retries: 1}, nil, "on-failure · 1 retry"},
		{flk.Restart{Policy: "never"}, nil, "never"},
		{flk.Restart{Policy: "always", Retries: 10}, &flk.Restarts{Count: 2, LastAt: "2026-10-12T07:00:00Z"},
			"always · 10 retries · restarted 2× (last 2026-10-12 07:00Z)"},
		{flk.Restart{Policy: "on-failure", Retries: 3}, &flk.Restarts{Count: 3, GaveUpAt: "2026-10-12T07:01:00Z"},
			"on-failure · 3 retries · gave up 2026-10-12 07:01Z after 3 restarts"},
	} {
		if got := ansi.Strip(restartText(c.r, c.n)); got != c.want {
			t.Errorf("got %q, want %q", got, c.want)
		}
	}
}

func TestTooSmall(t *testing.T) {
	m := demoModel(t, 79, 24)
	if got := m.Render(); got != "lazyflk needs a 80x24 terminal (this one is 79x24)" {
		t.Errorf("got %q", got)
	}
}

// A host with problems: the broken app sorts first and is flagged, and
// next_steps fill the attention panel (capped, with a pointer to the rest).
func TestProblemsFirst(t *testing.T) {
	hc := flk.HostContext{
		Flk:  flk.FlkInfo{StateDir: "/s"},
		Host: flk.Host{OK: true, LanIP: "10.0.0.1", BootService: true},
		Apps: []flk.App{
			{Name: "alpha", Registered: true, Machines: []flk.Machine{{ID: "a1", State: "started", DesiredState: "started"}}},
			{Name: "zeta", Registered: true, Machines: []flk.Machine{{ID: "z1", Name: "z-one", State: "stopped", DesiredState: "started"}},
				Volumes: []flk.Volume{{ID: "v1", Name: "data", SizeGB: 1, Path: "/s/apps/zeta/volumes/data.ext4"}}},
		},
		NextSteps: []string{"zeta: start it: flk -a zeta machine start z1", "b", "c", "d", "e"},
	}
	m := New(Options{Client: flk.New(flk.NewFake(fixtures.FS))})
	m.Update(tea.WindowSizeMsg{Width: 80, Height: 24})
	m.Update(contextMsg{hc: hc})
	if m.apps[0].Name != "zeta" {
		t.Errorf("order: %s first", m.apps[0].Name)
	}
	s := ansi.Strip(m.Render())
	checkSize(t, m.Render(), 80, 24)
	for _, want := range []string{"▾ zeta  0/1 ○ !", "! z-one", "▢ data 1GB  ", "! zeta: start it", "… 2 more: flk context --all",
		"machine z1 ! stopped, should be started", "! machine z1 should be running but is stopped", "! start it: flk -a zeta"} {
		if !strings.Contains(s, want) {
			t.Errorf("missing %q in:\n%s", want, s)
		}
	}
	if strings.Contains(s, "(external)") {
		t.Errorf("volume under the state dir isn't external:\n%s", s)
	}
}
