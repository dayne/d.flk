package ui

import (
	"context"
	"flag"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"

	"lazyflk/fixtures"
	"lazyflk/internal/flk"
	"lazyflk/internal/host"
	"lazyflk/internal/providers"
)

var update = flag.Bool("update", false, "rewrite testdata/*.golden")

func fixtureDisk(_ context.Context, paths []string) ([]host.Disk, error) {
	out, err := fs.ReadFile(fixtures.FS, "df.txt")
	if err != nil {
		return nil, err
	}
	return host.ParseDF(string(out), paths)
}

// runCmd runs a command and everything it batches, returning the messages.
// Commands still blocked after a moment (a followed log waiting for more
// output) are abandoned.
func runCmd(cmd tea.Cmd) []tea.Msg {
	if cmd == nil {
		return nil
	}
	ch := make(chan tea.Msg, 1)
	go func() { ch <- cmd() }()
	select {
	case msg := <-ch:
		if b, ok := msg.(tea.BatchMsg); ok {
			var out []tea.Msg
			for _, c := range b {
				out = append(out, runCmd(c)...)
			}
			return out
		}
		if msg == nil {
			return nil
		}
		return []tea.Msg{msg}
	case <-time.After(100 * time.Millisecond):
		return nil
	}
}

// send delivers msgs, then the results of every command they trigger,
// until the model settles.
func send(m *Model, msgs ...tea.Msg) {
	for len(msgs) > 0 {
		msg := msgs[0]
		msgs = msgs[1:]
		_, cmd := m.Update(msg)
		msgs = append(msgs, runCmd(cmd)...)
	}
}

func press(m *Model, keys ...string) {
	for _, k := range keys {
		send(m, key(k))
	}
}

func newDemo(fsys fs.FS) *Model {
	return New(Options{Client: flk.New(flk.NewFake(fsys)), Disk: fixtureDisk, Demo: true,
		Host:      (&providers.Fake{FS: fsys, Files: providers.DemoFiles}).For,
		Providers: []providers.Provider{providers.Storage{}, providers.Podman{Now: demoNow}, providers.Services{}}})
}

// demoNow is when the fixtures were captured, for anything showing ages.
func demoNow() time.Time { return time.Date(2026, 10, 13, 7, 0, 0, 0, time.UTC) }

// demoModel is the --demo model after its first load, sized w x h.
func demoModel(t *testing.T, w, h int) *Model {
	t.Helper()
	m := newDemo(fixtures.FS)
	send(m, tea.WindowSizeMsg{Width: w, Height: h})
	send(m, runCmd(m.Init())...) // no refresh: Init is just the load
	return m
}

func key(s string) tea.KeyPressMsg {
	codes := map[string]tea.Key{
		"up": {Code: tea.KeyUp}, "down": {Code: tea.KeyDown}, "left": {Code: tea.KeyLeft}, "right": {Code: tea.KeyRight},
		"tab": {Code: tea.KeyTab}, "shift+tab": {Code: tea.KeyTab, Mod: tea.ModShift},
		"pgdown": {Code: tea.KeyPgDown}, "pgup": {Code: tea.KeyPgUp},
		"esc": {Code: tea.KeyEscape}, "enter": {Code: tea.KeyEnter}, "backspace": {Code: tea.KeyBackspace},
		"ctrl+c": {Code: 'c', Mod: tea.ModCtrl},
	}
	if k, ok := codes[s]; ok {
		return tea.KeyPressMsg(k)
	}
	return tea.KeyPressMsg{Code: []rune(s)[0], Text: s}
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

// snap checks the screen's size and compares it with its golden file.
func snap(t *testing.T, m *Model, name string) {
	t.Helper()
	s := m.Render()
	checkSize(t, s, m.width, m.height)
	golden(t, fmt.Sprintf("%s-%dx%d", name, m.width, m.height), s)
}

// Every tab of every kind of selection, at both reference sizes.
func TestTabSnapshots(t *testing.T) {
	for _, sz := range [][2]int{{80, 24}, {160, 48}} {
		t.Run(fmt.Sprintf("%dx%d", sz[0], sz[1]), func(t *testing.T) {
			m := demoModel(t, sz[0], sz[1])
			kinds := map[string]nodeKind{"app": kindApp, "machine": kindMachine, "volume": kindVolume, "ports": kindPorts, "host": kindHost}
			for _, sel := range []string{"app", "machine", "volume", "ports", "host"} {
				goTo(m, kinds[sel])
				names := tabNames(m.nodes[m.cursor].kind)
				for i, tab := range names {
					press(m, fmt.Sprint(i+1))
					snap(t, m, "tab-"+sel+"-"+strings.ToLower(tab))
				}
				press(m, "1", "down")
			}
		})
	}
}

func TestLogsSnapshots(t *testing.T) {
	for _, sz := range [][2]int{{80, 24}, {160, 48}} {
		t.Run(fmt.Sprintf("%dx%d", sz[0], sz[1]), func(t *testing.T) {
			m := demoModel(t, sz[0], sz[1])
			press(m, "down", "l") // the machine
			snap(t, m, "logs-follow")
			press(m, "/", "R", "C", "O", "N", "enter")
			snap(t, m, "logs-search")
			press(m, "?")
			snap(t, m, "help-logs")
			press(m, "x", "esc")
			press(m, "?")
			snap(t, m, "help-main")
		})
	}
}

func TestNavigation(t *testing.T) {
	m := demoModel(t, 80, 24)
	sel := func() string { return m.nodes[m.cursor].key(m.apps) }
	if sel() != "app/minecraft-flk" {
		t.Fatalf("starts on %s", sel())
	}
	press(m, "up")
	if sel() != "app/minecraft-flk" {
		t.Errorf("up from the top moved to %s", sel())
	}
	for range 8 {
		press(m, "j")
	}
	if sel() != "host" {
		t.Errorf("after the apps is %s", sel())
	}
	for range 50 {
		press(m, "j")
	}
	if sel() != "prov/service/chrony.service" {
		t.Errorf("bottom is %s (the last provider item)", sel())
	}
	goTo(m, kindHost)
	press(m, "k")
	if sel() != "ports/vintagestory-flk" {
		t.Errorf("above host is %s", sel())
	}
	before := len(m.nodes)
	press(m, "left") // collapse from a child selects the app: its machine, volume and ports go
	if sel() != "app/vintagestory-flk" || len(m.nodes) != before-3 {
		t.Errorf("collapsed: on %s, %d nodes", sel(), len(m.nodes))
	}
	if !strings.Contains(m.Render(), "▸ vintagestory-flk") {
		t.Error("collapsed app should show ▸")
	}
	press(m, "right", "down")
	if sel() != "machine/vintagestory-flk/f8f979ffff11cf" {
		t.Errorf("expanded: on %s", sel())
	}
	// a refresh keeps the selection
	hc, _ := m.opt.Client.HostContext(context.Background())
	send(m, contextMsg{gen: m.loadGen, hc: hc})
	if sel() != "machine/vintagestory-flk/f8f979ffff11cf" {
		t.Errorf("after refresh: on %s", sel())
	}
	if _, cmd := m.Update(key("q")); cmd == nil {
		t.Error("q should quit")
	}
}

func TestTabs(t *testing.T) {
	m := demoModel(t, 80, 24)
	tab := func() string { return m.tabName(m.nodes[m.cursor]) }
	press(m, "tab", "tab")
	if tab() != "Ports" {
		t.Errorf("tab tab: %s", tab())
	}
	press(m, "shift+tab")
	if tab() != "Logs" {
		t.Errorf("shift+tab: %s", tab())
	}
	press(m, "shift+tab", "shift+tab")
	if tab() != "Config" {
		t.Errorf("wraps around: %s", tab())
	}
	press(m, "9") // no 9th tab: stays
	if tab() != "Config" {
		t.Errorf("9: %s", tab())
	}
	// each kind of selection remembers its own tab
	press(m, "down")
	if tab() != "Overview" {
		t.Errorf("machine: %s", tab())
	}
	press(m, "3", "up")
	if tab() != "Config" {
		t.Errorf("back on the app: %s", tab())
	}
	// long tabs scroll, and the scroll resets with the selection
	press(m, "pgdown")
	if m.detailTop == 0 || !strings.Contains(ansi.Strip(m.Render()), "above (pgup)") {
		t.Errorf("pgdown: top %d", m.detailTop)
	}
	press(m, "down", "up")
	if m.detailTop != 0 {
		t.Errorf("scroll kept after moving: %d", m.detailTop)
	}
}

// Tab data loads once, then again only when stale.
func TestTabFetchCaching(t *testing.T) {
	fake := flk.NewFake(fixtures.FS)
	m := New(Options{Client: flk.New(fake)})
	now := time.Date(2026, 10, 12, 8, 0, 0, 0, time.UTC)
	m.now = func() time.Time { return now }
	send(m, tea.WindowSizeMsg{Width: 80, Height: 24})
	send(m, runCmd(m.Init())...)
	count := func() int {
		n := 0
		for _, c := range fake.Calls() {
			if strings.Join(c, " ") == "-a minecraft-flk releases --json" {
				n++
			}
		}
		return n
	}
	press(m, "5", "down", "up", "down", "up")
	if count() != 1 {
		t.Errorf("releases fetched %d times", count())
	}
	now = now.Add(time.Minute)
	press(m, "down", "up")
	if count() != 2 {
		t.Errorf("stale releases fetched %d times in all", count())
	}
	if s := ansi.Strip(m.Render()); !strings.Contains(s, "v8   2026-10-12 07:08Z  Dockerfile  current") ||
		!strings.Contains(s, "     running on mellow-aurora-7882") {
		t.Errorf("releases tab:\n%s", ansi.Strip(m.Render()))
	}
}

// A failing flk shows its error in place of the data, then alongside stale data.
func TestFlkErrors(t *testing.T) {
	m := newDemo(os.DirFS(t.TempDir()))
	send(m, tea.WindowSizeMsg{Width: 80, Height: 24})
	send(m, runCmd(m.Init())...)
	s := ansi.Strip(m.Render())
	checkSize(t, m.Render(), 80, 24)
	for _, want := range []string{"flk error", "flk failed", "$ flk context --all --json", "Error: demo mode has no captured"} {
		if !strings.Contains(s, want) {
			t.Errorf("missing %q in:\n%s", want, s)
		}
	}

	m = demoModel(t, 80, 24)
	send(m, contextMsg{gen: m.loadGen, err: fmt.Errorf("Error: timed out\nsecond line")})
	s = ansi.Strip(m.Render())
	if !strings.Contains(s, "✘ refresh failed: Error: timed out") || !strings.Contains(s, "mellow-aurora-7882") {
		t.Errorf("stale data with error:\n%s", s)
	}

	// a tab whose command fails shows flk's error under the command
	m.cache["flk -a minecraft-flk releases --json"] = &fetched{err: fmt.Errorf("Error: app is locked"), at: m.now()}
	press(m, "5")
	s = ansi.Strip(m.Render())
	if !strings.Contains(s, "$ flk -a minecraft-flk releases --json") || !strings.Contains(s, "Error: app is locked") {
		t.Errorf("tab error:\n%s", s)
	}
}

func TestTooSmall(t *testing.T) {
	m := demoModel(t, 79, 24)
	if got := m.Render(); got != "lazyflk needs a 80x24 terminal (this one is 79x24)" {
		t.Errorf("got %q", got)
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

// A host with problems: the broken app sorts first and is flagged, and
// next_steps fill the attention panel, wrapped and capped.
func TestProblemsFirst(t *testing.T) {
	hc := flk.HostContext{
		Flk:  flk.FlkInfo{StateDir: "/s"},
		Host: flk.Host{OK: true, LanIP: "10.0.0.1", BootService: true},
		Apps: []flk.App{
			{Name: "alpha", Registered: true, Machines: []flk.Machine{{ID: "a1", State: "started", DesiredState: "started"}}},
			{Name: "zeta", Registered: true, Machines: []flk.Machine{{ID: "z1", Name: "z-one", State: "stopped", DesiredState: "started"}},
				Volumes: []flk.Volume{{ID: "v1", Name: "data", SizeGB: 1, Path: "/s/apps/zeta/volumes/data.ext4"}}},
		},
		NextSteps: []string{
			"zeta: machine z1 [z-one] is stopped; start it: flk machine start z1 (and this step is long enough to need a second line here)",
			"b", "c", "d", "e"},
	}
	m := New(Options{Client: flk.New(flk.NewFake(fixtures.FS))})
	send(m, tea.WindowSizeMsg{Width: 80, Height: 24})
	send(m, contextMsg{gen: m.loadGen, hc: hc})
	if m.apps[0].Name != "zeta" {
		t.Errorf("order: %s first", m.apps[0].Name)
	}
	s := ansi.Strip(m.Render())
	checkSize(t, m.Render(), 80, 24)
	for _, want := range []string{"▾ zeta  0/1 ○ !", "! z-one", "▢ data 1GB  ", "! zeta: machine z1 [z-one] is stopped",
		"   this step is long enough to need a second line here)", "! b", "… 3 more: flk context --all",
		"machine z1 ! stopped, should be started", "! machine z1 should be running but is stopped"} {
		if !strings.Contains(s, want) {
			t.Errorf("missing %q in:\n%s", want, s)
		}
	}
	if strings.Contains(s, "(external)") {
		t.Errorf("volume under the state dir isn't external:\n%s", s)
	}
}

func TestDiskWarnings(t *testing.T) {
	m := demoModel(t, 80, 24)
	if w := m.diskWarnings(); len(w) != 0 {
		t.Errorf("fixture disks are under 85%%: %v", w)
	}
	src := m.diskSource()
	m.cache[src.cmd].val = []host.Disk{{Target: "/", Percent: 96, AvailKB: 4 << 20, Paths: []string{"/home/dayne/.local/share/flk"}}}
	s := ansi.Strip(m.Render())
	if !strings.Contains(s, "! disk / is 96% full (4.0G free); it holds /home/dayne/.local/share/flk") {
		t.Errorf("no disk warning:\n%s", s)
	}
}

func TestTabBar(t *testing.T) {
	names := tabNames(kindApp)
	for _, c := range []struct {
		active, w int
		want      string
	}{
		{0, 80, " Overview  Logs  Ports  Volumes  Releases  Secrets  Config "},
		{0, 30, " Overview  Logs  Ports ›"},
		{6, 30, "‹ Releases  Secrets  Config "},
		{3, 30, "‹ Ports  Volumes  Releases ›"},
	} {
		if got := ansi.Strip(tabBar(names, c.active, c.w)); got != c.want {
			t.Errorf("active %d, w %d: %q, want %q", c.active, c.w, got, c.want)
		}
	}
}
