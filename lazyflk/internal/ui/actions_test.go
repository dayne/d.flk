package ui

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"

	"lazyflk/fixtures"
	"lazyflk/internal/flk"
)

// Tree rows in the demo: app, machine, volume, ports, then the host.
func goTo(m *Model, kind nodeKind) {
	for i, n := range m.nodes {
		if n.kind == kind {
			m.cursor = i
			return
		}
	}
}

func fake(m *Model) *flk.Fake { return m.opt.Client.Runner.(*flk.Fake) }

// actionCalls are the streamed commands run so far (actions, not reads).
func actionCalls(m *Model) []string {
	var out []string
	for _, j := range m.jobs {
		out = append(out, j.line)
	}
	return out
}

// withState changes the demo's context, as a refresh from flk would.
func withState(t *testing.T, m *Model, change func(hc *flk.HostContext)) {
	t.Helper()
	hc, err := m.opt.Client.HostContext(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	change(&hc)
	m.loadGen++
	send(m, contextMsg{gen: m.loadGen, hc: hc})
}

func screen(m *Model) string { return ansi.Strip(m.Render()) }

func TestActionSnapshots(t *testing.T) {
	for _, sz := range [][2]int{{80, 24}, {160, 48}} {
		m := demoModel(t, sz[0], sz[1])
		clock := time.Date(2026, 10, 12, 8, 0, 0, 0, time.UTC)
		m.now = func() time.Time { return clock }
		press(m, "enter")
		snap(t, m, "menu-app")
		press(m, "esc")

		goTo(m, kindMachine)
		press(m, "x")
		snap(t, m, "menu-machine")
		press(m, "S")
		snap(t, m, "confirm-stop")
		press(m, "y")
		snap(t, m, "job-done")
		press(m, "esc", "L")
		snap(t, m, "cmdlog")
		press(m, "esc")

		goTo(m, kindVolume)
		press(m, "enter")
		snap(t, m, "menu-volume")
		press(m, "esc")

		goTo(m, kindHost)
		press(m, "enter")
		snap(t, m, "menu-host")
		press(m, "esc")

		goTo(m, kindApp)
		press(m, "enter", "e")
		press(m, strings.Split("API_KEY", "")...)
		press(m, "tab", "s", "3", "c", "r", "3", "t")
		snap(t, m, "form-secret")
		press(m, "esc", "enter", "D", "m", "i", "n")
		snap(t, m, "confirm-destroy")
		press(m, "esc")

		withState(t, m, problems)
		press(m, "a", "down")
		snap(t, m, "attention")
	}
}

// problems gives the demo host the kinds of next_steps flk reports.
func problems(hc *flk.HostContext) {
	id := hc.Apps[0].Machines[0].ID
	hc.Apps[0].Machines[0].State = "stopped"
	hc.NextSteps = []string{
		"optional: port helper usable without a password -> sudo /home/dayne/flk/setup-host.sh",
		"minecraft-flk: machine " + id + " [mellow-aurora-7882] should be running but isn't (it exited, or the host restarted); " +
			"see why: flk logs -i " + id + " --no-tail; bring it back: flk resume",
		"minecraft-flk: host port tcp/25565 is held by another machine; this one gets it when that stops",
	}
}

// Stopping a machine: menu, confirm, then exactly the command shown runs,
// and lazyflk reloads what changed.
func TestStopMachine(t *testing.T) {
	m := demoModel(t, 80, 24)
	goTo(m, kindMachine)
	press(m, "s") // the shortcut: stop, as it's running
	if m.confirm == nil || !strings.Contains(screen(m), "$ flk -a minecraft-flk machine stop 225d58f615e7e6") {
		t.Fatalf("no confirm:\n%s", screen(m))
	}
	before := len(fake(m).Calls())
	press(m, "n")
	if m.confirm != nil || len(fake(m).Calls()) != before {
		t.Fatal("n should cancel without running anything")
	}
	press(m, "s", "y")
	want := []string{"-a", "minecraft-flk", "machine", "stop", "225d58f615e7e6"}
	calls := fake(m).Calls()
	if !reflect.DeepEqual(calls[before], want) {
		t.Errorf("ran %v", calls[before])
	}
	if !reflect.DeepEqual(calls[before+1], []string{"context", "--all", "--json", "--no-host"}) {
		t.Errorf("no reload after the action: %v", calls[before+1:])
	}
	j := m.shown
	if j == nil || j.running() || j.err != nil || j.line != flk.CommandLine(want...) {
		t.Fatalf("job: %+v", j)
	}
	if s := screen(m); !strings.Contains(s, "✔ done in") || !strings.Contains(s, "demo mode: flk was not run") {
		t.Errorf("job modal:\n%s", s)
	}
	press(m, "esc")
	if m.shown != nil {
		t.Error("esc closes the finished job")
	}
}

func TestDisabledAction(t *testing.T) {
	m := demoModel(t, 80, 24)
	goTo(m, kindMachine)
	press(m, "enter", "s") // start: already running
	if len(m.jobs) != 0 || m.menu == nil || !strings.Contains(screen(m), "start: already running") {
		t.Errorf("disabled action:\n%s", screen(m))
	}
}

// A secret's value goes to flk on stdin; it's never on screen, in the
// command line or in the command log.
func TestSecretValue(t *testing.T) {
	m := demoModel(t, 80, 24)
	press(m, "enter", "e")
	press(m, strings.Split("RCON_PASSWORD", "")...)
	press(m, "tab")
	send(m, tea.PasteMsg{Content: "hunter2\n"})
	press(m, "tab", "right", "enter") // apply: later
	if s := screen(m); strings.Contains(s, "hunter2") || !strings.Contains(s, "secrets set RCON_PASSWORD=- --stage") {
		t.Errorf("confirm:\n%s", s)
	}
	press(m, "y")
	if st := fake(m).Stdins(); len(st) != 1 || st[0] != "hunter2\n" {
		t.Errorf("stdin %q", st)
	}
	press(m, "esc", "L")
	if s := screen(m); strings.Contains(s, "hunter2") || !strings.Contains(s, "flk -a minecraft-flk secrets set RCON_PASSWORD=- --stage") {
		t.Errorf("command log:\n%s", s)
	}
	for _, j := range m.jobs {
		if strings.Contains(strings.Join(j.args, " ")+j.line, "hunter2") {
			t.Error("job holds the secret")
		}
	}
}

func TestFormChecks(t *testing.T) {
	m := demoModel(t, 80, 24)
	press(m, "enter", "e", "enter")
	if m.form == nil || !strings.Contains(screen(m), "! name is required") {
		t.Errorf("empty name:\n%s", screen(m))
	}
	press(m, "esc", "enter", "c", "backspace", "x", "enter")
	if m.form == nil || !strings.Contains(screen(m), "machines must be a whole number") {
		t.Errorf("scale x:\n%s", screen(m))
	}
}

// Destroying needs the name typed exactly.
func TestTypedConfirm(t *testing.T) {
	m := demoModel(t, 80, 24)
	press(m, "enter", "D")
	press(m, strings.Split("minecraft", "")...)
	press(m, "enter")
	if m.confirm == nil || len(m.jobs) != 0 {
		t.Fatal("a partial name must not run it")
	}
	press(m, strings.Split("-flk", "")...)
	if !strings.Contains(screen(m), "✔ enter runs it") {
		t.Errorf("typed:\n%s", screen(m))
	}
	press(m, "enter")
	if got := actionCalls(m); len(got) != 1 || got[0] != "flk apps destroy minecraft-flk --yes" {
		t.Errorf("ran %v", got)
	}
}

func TestReadOnly(t *testing.T) {
	m := New(Options{Client: flk.New(flk.NewFake(fixtures.FS)), Disk: fixtureDisk, Demo: true, ReadOnly: true})
	send(m, tea.WindowSizeMsg{Width: 80, Height: 24})
	send(m, runCmd(m.Init())...)
	if s := screen(m); strings.Contains(s, "enter actions") || !strings.Contains(s, "read-only") {
		t.Errorf("footer:\n%s", s)
	}
	press(m, "enter")
	if m.menu != nil || !strings.Contains(screen(m), "read-only: actions are off") {
		t.Error("read-only opened the menu")
	}
	goTo(m, kindMachine)
	press(m, "s", "d", "y")
	withState(t, m, problems)
	press(m, "a", "down", "enter", "y")
	if len(m.jobs) != 0 {
		t.Errorf("read-only ran %v", actionCalls(m))
	}
}

// Needs attention: a selects, enter runs the step's fix (scoped to its app).
func TestAttentionFix(t *testing.T) {
	m := demoModel(t, 80, 24)
	withState(t, m, problems)
	press(m, "a")
	if !strings.Contains(screen(m), "→ enter: copy: sudo /home/dayne/flk/setup-host.sh") {
		t.Errorf("root step:\n%s", screen(m))
	}
	press(m, "down", "enter")
	if m.confirm == nil || !strings.Contains(screen(m), "$ flk -a minecraft-flk resume") {
		t.Fatalf("fix:\n%s", screen(m))
	}
	press(m, "y")
	if got := actionCalls(m); len(got) != 1 || got[0] != "flk -a minecraft-flk resume" {
		t.Errorf("ran %v", got)
	}
	press(m, "esc")
	if len(m.hc.NextSteps) != 0 {
		t.Error("the action should reload the context")
	}
	withState(t, m, problems)
	press(m, "a", "down", "down", "enter")
	if !strings.Contains(screen(m), "no fix lazyflk can run") {
		t.Errorf("no fix:\n%s", screen(m))
	}
}

func TestFailedAction(t *testing.T) {
	m := demoModel(t, 80, 24)
	fake(m).Fail = func(args []string) error {
		return &flk.Error{Args: args, Stderr: "Error: flk is busy (another command holds the lock)"}
	}
	goTo(m, kindHost)
	press(m, "enter", "p")
	if s := screen(m); !strings.Contains(s, "✘ failed") || !strings.Contains(s, "Error: flk is busy") {
		t.Errorf("failure:\n%s", s)
	}
}

// q while a job runs warns first; the second q interrupts it and quits
// once it has ended.
func TestQuitWhileRunning(t *testing.T) {
	m := demoModel(t, 80, 24)
	j := &job{line: "flk -a flkt-x deploy", args: []string{"-a", "flkt-x", "deploy"}, started: m.now()}
	m.jobs = append(m.jobs, j)
	if _, cmd := m.Update(key("q")); cmd != nil && m.quitting {
		t.Fatal("first q quit")
	}
	if !strings.Contains(screen(m), "is still running: press q again") {
		t.Errorf("warning:\n%s", screen(m))
	}
	m.Update(key("q"))
	if !m.quitting || !j.stopped || m.shown != j {
		t.Fatalf("second q: quitting %v stopped %v", m.quitting, j.stopped)
	}
	if cmd := m.jobEnded(j); cmd == nil {
		t.Error("should quit once the job ends")
	} else if _, ok := cmd().(tea.QuitMsg); !ok {
		t.Error("not a quit")
	}
}

// SPEC 8: through a fake flk binary, each action runs exactly the command
// it displays (the shell's reading of the displayed line is the argv).
func TestRunsWhatItShows(t *testing.T) {
	dir := t.TempDir()
	ctxJSON, _ := fixtures.FS.ReadFile("context-all.json")
	os.WriteFile(filepath.Join(dir, "context.json"), ctxJSON, 0o644)
	quickJSON, _ := fixtures.FS.ReadFile("context-all-nohost.json")
	os.WriteFile(filepath.Join(dir, "quick.json"), quickJSON, 0o644)
	log := filepath.Join(dir, "argv")
	script := filepath.Join(dir, "flk")
	os.WriteFile(script, []byte(`#!/bin/sh
printf '%s\0' "$@" >> `+log+`
printf '\n' >> `+log+`
[ "$*" = "context --all --json" ] && cat `+filepath.Join(dir, "context.json")+`
[ "$*" = "context --all --json --no-host" ] && cat `+filepath.Join(dir, "quick.json")+`
exit 0
`), 0o755)
	m := New(Options{Client: flk.New(flk.Exec{Path: script})})
	send(m, tea.WindowSizeMsg{Width: 80, Height: 24})
	send(m, runCmd(m.Init())...)
	if m.hc == nil {
		t.Fatal("no context")
	}
	run := func(keys ...string) {
		press(m, keys...)
		for m.runningJob() != nil {
			send(m, runCmd(nil)...)
		}
		press(m, "esc")
	}
	goTo(m, kindMachine)
	run("enter", "r", "y")
	goTo(m, kindApp)
	run("enter", "n", "w", "o", "r", "l", "d", " ", "2", "tab", "backspace", "5", "tab", "tab", "/", "s", "r", "v", "/", "o", "l", "d", " ", "w", "o", "r", "l", "d", "enter")
	run("enter", "c", "enter", "y")

	if len(m.jobs) != 3 {
		t.Fatalf("%d jobs: %v", len(m.jobs), actionCalls(m))
	}
	raw, _ := os.ReadFile(log)
	var ran [][]string
	for _, rec := range strings.Split(strings.TrimSuffix(string(raw), "\n"), "\n") {
		argv := strings.Split(strings.TrimSuffix(rec, "\x00"), "\x00")
		if !isRead(argv) {
			ran = append(ran, argv)
		}
	}
	for i, j := range m.jobs {
		out, err := exec.Command("sh", "-c", `flk() { printf '%s\0' "$@"; }; `+j.line).Output()
		if err != nil {
			t.Fatal(err)
		}
		shown := strings.Split(strings.TrimSuffix(string(out), "\x00"), "\x00")
		if i >= len(ran) || !reflect.DeepEqual(shown, ran[i]) {
			t.Errorf("showed %q, ran %q", shown, ran)
		}
	}
	if !strings.Contains(m.jobs[1].line, "'world 2'") || !strings.Contains(m.jobs[1].line, "'/srv/old world'") {
		t.Errorf("quoting: %s", m.jobs[1].line)
	}
}

// isRead is a command lazyflk runs on its own to show things, not an action.
func isRead(argv []string) bool {
	line := strings.Join(argv, " ")
	for _, p := range []string{"context --all --json", "doctor --json", "machine stats --all --json", "disk --json", "images --json", "help --all --json"} {
		if strings.HasPrefix(line, p) {
			return true
		}
	}
	return false
}
