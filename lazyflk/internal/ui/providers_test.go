package ui

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"lazyflk/internal/flk"
)

func goToKey(t *testing.T, m *Model, key string) {
	t.Helper()
	for i, n := range m.nodes {
		if n.key(m.apps) == key {
			m.cursor = i
			send(m) // let sync load what it shows
			return
		}
	}
	t.Fatalf("no node %s", key)
}

func TestProviderSnapshots(t *testing.T) {
	for _, sz := range [][2]int{{80, 24}, {160, 48}} {
		m := demoModel(t, sz[0], sz[1])
		goToKey(t, m, "prov/storage//data/minecraft")
		snap(t, m, "prov-storage")
		goToKey(t, m, "prov/podman/c/f7cd17e4bfbcde38fc0f8004e487566b35476a57b502a4ea6f7a703825b6695f")
		snap(t, m, "prov-podman-build")
		press(m, "enter")
		snap(t, m, "prov-podman-menu")
		press(m, "esc")
		goToKey(t, m, "prov/service/ssh.service")
		snap(t, m, "prov-service")
		goToKey(t, m, "prov/service/chrony.service")
		press(m, "l")
		snap(t, m, "prov-journal")
		press(m, "esc")
	}
}

func TestProviderActions(t *testing.T) {
	m := demoModel(t, 100, 30)
	// the build container is in Needs attention, with a typed-confirm fix
	var fix *attnItem
	for _, it := range m.attnItems() {
		if strings.Contains(it.text, "ruby-working-container was left behind") {
			it := it
			fix = &it
		}
	}
	if fix == nil || fix.fix == nil {
		t.Fatalf("no attention item: %+v", m.attnItems())
	}
	goToKey(t, m, "prov/podman/c/f7cd17e4bfbcde38fc0f8004e487566b35476a57b502a4ea6f7a703825b6695f")
	press(m, "enter", "D")
	if m.confirm == nil || !strings.Contains(screen(m), "$ podman rm --storage f7cd17e4bfbc") ||
		!strings.Contains(screen(m), "Type ruby-working-container to confirm") {
		t.Fatalf("confirm:\n%s", screen(m))
	}
	typeText(m, "ruby-working-container")
	press(m, "enter")
	if len(m.jobs) != 1 || m.jobs[0].line != "podman rm --storage f7cd17e4bfbc" ||
		!strings.Contains(screen(m), "demo mode: podman was not run") {
		t.Errorf("job: %v\n%s", actionCalls(m), screen(m))
	}
	press(m, "esc")

	// root steps are copied, never run
	goToKey(t, m, "prov/service/ssh.service")
	press(m, "enter", "r")
	if len(m.jobs) != 1 || !strings.Contains(screen(m), "copied (if your terminal allows OSC 52): sudo systemctl restart ssh.service") {
		t.Errorf("restart:\n%s", screen(m))
	}

	// journal logs follow in the logs view
	press(m, "esc")
	goToKey(t, m, "prov/service/chrony.service")
	press(m, "l")
	if m.logs == nil || len(m.logs.lines) == 0 || !strings.Contains(screen(m), "$ journalctl -u chrony.service -f -n 200") {
		t.Errorf("journal:\n%s", screen(m))
	}
}

// An app's .lazyflk.toml adds its own actions to its menu.
func TestAppActionsMenu(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, ".lazyflk.toml"), []byte(`[actions]
save = "flk -a {app} console {machine} --send save-all"
[actions.say]
run = "flk -a {app} console {machine} --send 'say {input}'"
help = "broadcast a message"
`), 0o644)
	m := demoModel(t, 100, 30)
	withState(t, m, func(hc *flk.HostContext) { hc.Apps[0].ConfigPath = filepath.Join(dir, "flk.toml") })
	goTo(m, kindMachine)
	press(m, "enter")
	s := screen(m)
	if !strings.Contains(s, "save") || !strings.Contains(s, "broadcast a message") {
		t.Fatalf("menu:\n%s", s)
	}
	press(m, "2")
	typeText(m, "hi; reboot")
	press(m, "enter")
	if m.form == nil || !strings.Contains(screen(m), "the input can't contain") {
		t.Fatalf("unsafe input:\n%s", screen(m))
	}
	for range 8 {
		press(m, "backspace")
	}
	typeText(m, " back soon")
	press(m, "enter", "y")
	want := "sh -c 'cd '\\''" + dir + "'\\'' && flk -a minecraft-flk console 225d58f615e7e6 --send '\\''say hi back soon'\\'''"
	if len(m.jobs) != 1 || m.jobs[0].line != want {
		t.Errorf("ran %v\nwant %s", actionCalls(m), want)
	}
}
