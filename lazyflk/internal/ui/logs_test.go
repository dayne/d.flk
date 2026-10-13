package ui

import (
	"fmt"
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"

	"lazyflk/fixtures"
	"lazyflk/internal/flk"
)

func TestClassifyLog(t *testing.T) {
	name := func(id string) string { return "mellow (" + id + ")" }
	for _, c := range []struct {
		in   flk.Line
		text string
		kind logKind
	}{
		{flk.Line{Text: "[23:08] Done!\r\r"}, "[23:08] Done!", logText},
		{flk.Line{Text: "Copying blob 10%\rCopying blob 55%\r"}, "Copying blob 55%", logText},
		{flk.Line{Text: "\x1b[32;1mnew Geyser\x1b[0m\tok"}, "new Geyser    ok", logText},
		{flk.Line{Text: "--- flk: booting 225d (release v8) at 2026-10-12T07:08:00Z ---"},
			"--- flk: booting 225d (release v8) at 2026-10-12T07:08:00Z ---", logBanner},
		{flk.Line{Text: "==> /home/u/.local/share/flk/apps/a/machines/225d/console.log <=="}, "── mellow (225d) ──", logHeader},
		{flk.Line{Text: "tail: '/x/console.log' has been replaced;  following new file", Stderr: true},
			"── log rotated (older lines are in console.log.1) ──", logBanner},
		{flk.Line{Text: "tail: cannot open 'x'", Stderr: true}, "tail: cannot open 'x'", logError},
	} {
		got := classifyLog(c.in, name)
		if got.text != c.text || got.kind != c.kind || got.lower != strings.ToLower(c.text) {
			t.Errorf("%q: got %q kind %d", c.in.Text, got.text, got.kind)
		}
	}
}

func TestHighlight(t *testing.T) {
	got := highlight("RCON rcon Rcon", "rcon")
	if ansi.Strip(got) != "RCON rcon Rcon" || got == "RCON rcon Rcon" {
		t.Errorf("got %q", got)
	}
	if highlight("abc", "") != "abc" {
		t.Error("empty query should do nothing")
	}
}

// logsWith is a view holding n numbered lines, not streaming.
func logsWith(n int, machines ...flk.Machine) *logsView {
	v := newLogsView(nil, "app", machines, -1)
	v.follow = true
	for i := range n {
		v.lines = append(v.lines, classifyLog(flk.Line{Text: fmt.Sprintf("line %d", i)}, nil))
	}
	return v
}

func TestLogsScrollAndFollow(t *testing.T) {
	const w, h = 76, 10
	v := logsWith(100)
	if got := v.firstShown(w, h); got != 90 {
		t.Fatalf("following shows from %d", got)
	}
	v.key(key("up"), w, h)
	if v.follow || v.firstShown(w, h) != 89 {
		t.Errorf("up: follow %v, from %d", v.follow, v.firstShown(w, h))
	}
	v.key(key("g"), w, h)
	if v.firstShown(w, h) != 0 {
		t.Errorf("g: from %d", v.firstShown(w, h))
	}
	v.key(key("pgdown"), w, h)
	if v.firstShown(w, h) != 10 {
		t.Errorf("pgdown: from %d", v.firstShown(w, h))
	}
	for range 10 {
		v.key(key("pgdown"), w, h)
	}
	if !v.follow {
		t.Error("scrolling to the bottom follows again")
	}
	v.key(key("f"), w, h)
	if v.follow || v.firstShown(w, h) != 90 {
		t.Errorf("f pauses in place: follow %v from %d", v.follow, v.firstShown(w, h))
	}
	v.key(key("G"), w, h)
	if !v.follow {
		t.Error("G follows")
	}
	// wrapped lines take more rows, so fewer fit
	v.lines = append(v.lines, classifyLog(flk.Line{Text: strings.Repeat("x", 3*w)}, nil))
	v.key(key("w"), w, h)
	if got := v.firstShown(w, h); got != 93 { // 7 lines and the 3-row one
		t.Errorf("wrapped: from %d", got)
	}
	if _, open := v.key(key("esc"), w, h); open {
		t.Error("esc closes")
	}
}

func TestLogsSearch(t *testing.T) {
	const w, h = 76, 10
	v := logsWith(100)
	for _, k := range []string{"/", "l", "i", "n", "e", " ", "4", "backspace", "5", "enter"} {
		v.key(key(k), w, h)
	}
	if v.query != "line 5" || v.match != 59 || v.follow {
		t.Fatalf("query %q, match %d, follow %v", v.query, v.match, v.follow)
	}
	if pos, total := v.matchCount(); pos != 11 || total != 11 {
		t.Errorf("match %d of %d", pos, total)
	}
	v.key(key("N"), w, h)
	if v.match != 58 {
		t.Errorf("N: %d", v.match)
	}
	v.key(key("n"), w, h)
	v.key(key("n"), w, h)
	if v.match != 5 { // wraps around to the first
		t.Errorf("n past the last: %d", v.match)
	}
	if v.firstShown(w, h) > 5 || v.firstShown(w, h)+h <= 5 {
		t.Errorf("match at 5 not on screen from %d", v.firstShown(w, h))
	}
	if s := ansi.Strip(v.render(80, 15)); !strings.Contains(s, "/line 5 1/11") || !strings.Contains(s, "paused") {
		t.Errorf("status:\n%s", s)
	}
	v.key(key("/"), w, h)
	for _, k := range []string{"ctrl+u", "z", "enter"} {
		if k == "ctrl+u" {
			v.input = ""
			continue
		}
		v.key(key(k), w, h)
	}
	if v.match != -1 || !strings.Contains(ansi.Strip(v.render(80, 15)), `no match for "z"`) {
		t.Errorf("no match: %d", v.match)
	}
	v.key(key("j"), w, h)
	if v.note != "" {
		t.Error("the note clears on the next key")
	}
}

// [ and ] cycle all machines, then each one, restarting the stream.
func TestLogsMachines(t *testing.T) {
	m1, m2 := flk.Machine{ID: "aaa", Name: "one"}, flk.Machine{ID: "bbb", Name: "two"}
	v := newLogsView(flk.New(flk.NewFake(fixtures.FS)), "app", []flk.Machine{m1, m2}, -1)
	var seen []string
	for range 4 {
		v.key(key("]"), 76, 10)
		seen = append(seen, v.target()+": "+strings.Join(v.args(), " "))
	}
	want := []string{
		"one: -a app logs -i aaa -n 1000 -f",
		"two: -a app logs -i bbb -n 1000 -f",
		"all machines: -a app logs -n 1000 -f",
		"one: -a app logs -i aaa -n 1000 -f",
	}
	if strings.Join(seen, "\n") != strings.Join(want, "\n") {
		t.Errorf("got\n%s", strings.Join(seen, "\n"))
	}
	v.key(key("["), 76, 10)
	if v.sel != -1 || v.gen != 5 {
		t.Errorf("[: sel %d gen %d", v.sel, v.gen)
	}
	// output from an older stream is dropped
	if cmd := v.handleChunk(logChunkMsg{v: v, gen: 4, lines: []flk.Line{{Text: "old"}}}); cmd != nil || len(v.lines) != 0 {
		t.Error("stale chunk was used")
	}
}

func TestLogsKeepsBounded(t *testing.T) {
	v := logsWith(0)
	v.stream = &flk.Stream{}
	v.top, v.match = 100, 50
	lines := make([]flk.Line, logMax+10)
	v.handleChunk(logChunkMsg{v: v, gen: v.gen, lines: lines, done: true})
	if len(v.lines) != logMax || v.top != 90 || v.match != 40 || !v.ended {
		t.Errorf("%d lines, top %d, match %d, ended %v", len(v.lines), v.top, v.match, v.ended)
	}
}

// The logs screen opens on the selection, streams, and closes cleanly.
func TestLogsScreen(t *testing.T) {
	m := demoModel(t, 80, 24)
	press(m, "l")
	if m.logs == nil || m.logs.sel != -1 || len(m.logs.lines) != 40 || !m.logs.follow {
		t.Fatalf("app logs: %+v", m.logs)
	}
	if s := ansi.Strip(m.Render()); !strings.Contains(s, "$ flk -a minecraft-flk logs -n 1000 -f") ||
		!strings.Contains(s, "Logs ─ minecraft-flk / mellow-aurora-7882") {
		t.Errorf("screen:\n%s", s)
	}
	stream := m.logs.stream
	press(m, "q")
	if m.logs != nil {
		t.Fatal("q closes the logs")
	}
	if _, ok := <-stream.Lines; ok {
		t.Error("closing should stop flk logs -f")
	}
	press(m, "j", "j", "l") // a volume opens its app's logs
	if m.logs == nil || m.logs.app != "minecraft-flk" {
		t.Error("volume: no logs")
	}
	press(m, "esc")
	goTo(m, kindHost)
	press(m, "l") // the host has none
	if m.logs != nil {
		t.Error("host: logs opened")
	}
}
