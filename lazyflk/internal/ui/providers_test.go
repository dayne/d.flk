package ui

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"lazyflk/fixtures"
	"lazyflk/internal/actions"
	"lazyflk/internal/flk"
	"lazyflk/internal/providers"
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

// firstImageID is the fixture's first image that isn't flk's.
func firstImageID(t *testing.T) string {
	t.Helper()
	var imgs []struct {
		ID    string   `json:"Id"`
		Names []string `json:"Names"`
	}
	raw, _ := fixtures.FS.ReadFile("podman-images.json")
	json.Unmarshal(raw, &imgs)
	for _, im := range imgs {
		if len(im.Names) > 0 && !strings.HasPrefix(im.Names[0], "flk.local/") {
			return im.ID
		}
	}
	t.Fatal("no non-flk image in the fixture")
	return ""
}

func TestProviderSnapshots(t *testing.T) {
	for _, sz := range [][2]int{{80, 24}, {160, 48}} {
		m := demoModel(t, sz[0], sz[1])
		goToKey(t, m, "prov/storage//data/minecraft")
		snap(t, m, "prov-storage")
		goToKey(t, m, "prov/podman/i/"+firstImageID(t))
		snap(t, m, "prov-podman-image")
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

// stubProvider has one item whose action needs the name typed, like a
// leftover build container (the live fixture may have none).
type stubProvider struct{}

func (stubProvider) Name() string    { return "Stub" }
func (stubProvider) Command() string { return "stub list" }
func (stubProvider) Load(context.Context, providers.Host, providers.Env) ([]providers.Item, error) {
	rm := actions.Run("D", "remove", "remove it", actions.Type, "old-build",
		actions.Command{Program: "buildah", Args: []string{"rm", "0123456789ab"}})
	return []providers.Item{{Key: "stub/1", Label: "▢ old-build (build)", State: providers.Warn, Title: "container old-build",
		Problems: []string{"stub: old-build was left behind"}, Fix: &rm, Actions: []actions.Action{rm}}}, nil
}

func TestProviderActions(t *testing.T) {
	m := demoModel(t, 100, 30)
	m.opt.Providers = append(m.opt.Providers, stubProvider{})
	send(m, runCmd(m.reload())...)
	// a provider's problem is in Needs attention, with its fix
	var fix *attnItem
	for _, it := range m.attnItems() {
		if it.text == "stub: old-build was left behind" {
			it := it
			fix = &it
		}
	}
	if fix == nil || fix.fix == nil {
		t.Fatalf("no attention item: %+v", m.attnItems())
	}
	goToKey(t, m, "prov/stub/1")
	press(m, "enter", "D")
	if m.confirm == nil || !strings.Contains(screen(m), "$ buildah rm 0123456789ab") ||
		!strings.Contains(screen(m), "Type old-build to confirm") {
		t.Fatalf("confirm:\n%s", screen(m))
	}
	typeText(m, "old-build")
	press(m, "enter")
	if len(m.jobs) != 1 || m.jobs[0].line != "buildah rm 0123456789ab" ||
		!strings.Contains(screen(m), "demo mode: buildah was not run") {
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
	typeText(m, "don't panic; reboot")
	press(m, "enter", "y")
	// the text goes to sh as $1: shown and run as data, never as code
	want := flk.CommandLineFor("sh", "-c", "cd '"+dir+`' && flk -a minecraft-flk console 225d58f615e7e6 --send 'say '"$1"''`,
		"lazyflk-input", "don't panic; reboot")
	if len(m.jobs) != 1 || m.jobs[0].line != want {
		t.Errorf("ran %v\nwant %s", actionCalls(m), want)
	}
}
