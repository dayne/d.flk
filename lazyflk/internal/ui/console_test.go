package ui

import (
	"errors"
	"reflect"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"

	"lazyflk/fixtures"
	"lazyflk/internal/flk"
)

func typeText(m *Model, s string) {
	for _, r := range s {
		press(m, string(r))
	}
}

func lastCall(m *Model) []string {
	calls := fake(m).Calls()
	for i := len(calls) - 1; i >= 0; i-- {
		if !isRead(calls[i]) {
			return calls[i]
		}
	}
	return nil
}

func TestM3Snapshots(t *testing.T) {
	for _, sz := range [][2]int{{80, 24}, {160, 48}} {
		m := demoModel(t, sz[0], sz[1])
		press(m, ":")
		snap(t, m, "palette")
		typeText(m, "vol back")
		snap(t, m, "palette-search")
		press(m, "enter")
		snap(t, m, "palette-form")
		press(m, "esc")

		goTo(m, kindMachine)
		press(m, "c")
		snap(t, m, "attach")
		press(m, "esc", ">")
		typeText(m, "say hi")
		snap(t, m, "logs-send")
		press(m, "esc", "esc")

		press(m, "H")
		snap(t, m, "guides")
		press(m, "enter")
		snap(t, m, "guide-cheatsheet")
		press(m, "esc", "esc")
	}
}

func TestPaletteFindsAndRuns(t *testing.T) {
	m := demoModel(t, 80, 24)
	goTo(m, kindMachine)
	press(m, ":")
	typeText(m, "machine status")
	if got := m.paletteMatches(); len(got) == 0 || got[0].Name != "machine status" {
		t.Fatalf("matches: %v", got)
	}
	press(m, "enter")
	if m.form == nil || m.form.vals["-a"] != "minecraft-flk" {
		t.Fatalf("form: %+v", m.form)
	}
	press(m, "tab")
	typeText(m, "mellow-aurora-7882")
	press(m, "enter") // read-only: no confirm
	want := []string{"-a", "minecraft-flk", "machine", "status", "mellow-aurora-7882"}
	if got := lastCall(m); !reflect.DeepEqual(got, want) {
		t.Errorf("ran %v", got)
	}
	if m.shown == nil || !strings.Contains(screen(m), `"state": "started"`) {
		t.Errorf("output:\n%s", screen(m))
	}
}

// Palette destroys want the name typed, and get --yes from that.
func TestPaletteDestroy(t *testing.T) {
	m := demoModel(t, 80, 24)
	press(m, ":")
	typeText(m, "apps destroy")
	press(m, "enter")
	typeText(m, "flkt-gone")
	press(m, "enter")
	if m.confirm == nil || !strings.Contains(screen(m), "Type flkt-gone to confirm") {
		t.Fatalf("confirm:\n%s", screen(m))
	}
	press(m, "y", "enter")
	if len(m.jobs) != 0 {
		t.Fatal("y must not confirm a destroy")
	}
	press(m, "backspace")
	typeText(m, "flkt-gone")
	press(m, "enter")
	if got := lastCall(m); strings.Join(got, " ") != "apps destroy flkt-gone --yes" {
		t.Errorf("ran %v", got)
	}
}

func TestPaletteNotHere(t *testing.T) {
	m := demoModel(t, 80, 24)
	press(m, ":")
	typeText(m, "secrets set")
	press(m, "enter")
	if m.form != nil || m.palette == nil || !strings.Contains(screen(m), "not here: it would put the value on the command line") {
		t.Errorf("secrets set:\n%s", screen(m))
	}

	ro := New(Options{Client: flk.New(flk.NewFake(fixtures.FS)), Demo: true, ReadOnly: true})
	send(ro, tea.WindowSizeMsg{Width: 80, Height: 24})
	send(ro, runCmd(ro.Init())...)
	press(ro, ":")
	typeText(ro, "machine stop")
	press(ro, "enter")
	if ro.form != nil {
		t.Error("read-only ran machine stop")
	}
	press(ro, "ctrl+u")
	typeText(ro, "version")
	press(ro, "enter")
	if ro.shown == nil {
		t.Error("read-only can still look")
	}
}

// console without --send attaches (after the detach keys), not a job.
func TestPaletteConsole(t *testing.T) {
	m := demoModel(t, 80, 24)
	press(m, ":")
	typeText(m, "console")
	if m.paletteMatches()[0].Name != "console" {
		t.Fatalf("first match %s", m.paletteMatches()[0].Name)
	}
	press(m, "enter", "tab")
	typeText(m, "225d")
	press(m, "enter")
	if m.attach == nil || strings.Join(m.attach.args, " ") != "-a minecraft-flk console 225d" {
		t.Fatalf("attach: %+v\n%s", m.attach, screen(m))
	}
	press(m, "enter")
	if len(m.jobs) != 0 || !strings.Contains(screen(m), "demo mode: would run flk -a minecraft-flk console 225d") {
		t.Errorf("demo attach:\n%s", screen(m))
	}
}

func TestAttach(t *testing.T) {
	t.Setenv("TMUX", "/tmp/tmux-1000/default,1,0")
	m := demoModel(t, 80, 24)
	press(m, "c") // the app has one machine
	if m.attach == nil || !strings.Contains(screen(m), "Ctrl-b Ctrl-b d (you're inside tmux") {
		t.Fatalf("attach screen:\n%s", screen(m))
	}
	press(m, "esc")
	withState(t, m, func(hc *flk.HostContext) { hc.Apps[0].Machines[0].State = "stopped" })
	press(m, "c")
	if m.attach != nil || !strings.Contains(screen(m), "isn't running") {
		t.Error("attach to a stopped machine")
	}

	// back from a failed attach: the job says why
	j := &job{line: "flk -a x console y", args: []string{"-a", "x", "console", "y"}, started: m.now()}
	m.addJob(j)
	tail := &tailBuffer{}
	tail.Write([]byte("Error: machine y isn't running\n"))
	send(m, attachDoneMsg{j, errors.New("exit status 1"), tail})
	if j.running() || !strings.Contains(screen(m), "console: Error: machine y isn't running") {
		t.Errorf("after attach:\n%s", screen(m))
	}
}

// > types into the console and the answer arrives in the followed log.
func TestSendLine(t *testing.T) {
	m := demoModel(t, 80, 24)
	goTo(m, kindMachine)
	press(m, ">")
	if m.logs == nil || !m.logs.sending {
		t.Fatal("> opens the logs with the prompt")
	}
	press(m, "?") // typed, not help
	press(m, "backspace")
	typeText(m, "say hi")
	press(m, "enter")
	want := []string{"-a", "minecraft-flk", "console", "225d58f615e7e6", "--send", "say hi"}
	if got := lastCall(m); !reflect.DeepEqual(got, want) {
		t.Errorf("ran %v", got)
	}
	if m.shown != nil || m.logs == nil || !strings.Contains(screen(m), "sent: say hi") {
		t.Errorf("after send:\n%s", screen(m))
	}
	press(m, "esc", "L")
	if !strings.Contains(screen(m), "flk -a minecraft-flk console 225d58f615e7e6 --send 'say hi'") {
		t.Errorf("command log:\n%s", screen(m))
	}
}

func TestGuides(t *testing.T) {
	m := demoModel(t, 80, 24)
	press(m, "H")
	if got := m.topics(); strings.Join(got, " ") != "cheatsheet install first-app operate troubleshoot uninstall" {
		t.Errorf("topics %v", got)
	}
	press(m, "down", "down", "down", "enter") // operate
	if !strings.Contains(screen(m), "flk help operate") {
		t.Fatalf("operate:\n%s", screen(m))
	}
	press(m, "/")
	typeText(m, "backup")
	press(m, "enter")
	if g := m.guides; g.match < 0 || !strings.Contains(strings.ToLower(screen(m)), "backup") {
		t.Errorf("search: match %d\n%s", g.match, screen(m))
	}
	press(m, "esc", "esc")
	if m.guides != nil {
		t.Error("esc twice closes the guides")
	}
}
