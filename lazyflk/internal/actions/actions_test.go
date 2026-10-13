package actions

import (
	"encoding/json"
	"strconv"
	"strings"
	"testing"

	"lazyflk/fixtures"
	"lazyflk/internal/flk"
)

func hostContext(t *testing.T) flk.HostContext {
	t.Helper()
	b, err := fixtures.FS.ReadFile("context-all.json")
	if err != nil {
		t.Fatal(err)
	}
	var hc flk.HostContext
	if err := json.Unmarshal(b, &hc); err != nil {
		t.Fatal(err)
	}
	return hc
}

func find(t *testing.T, acts []Action, label string) Action {
	t.Helper()
	for _, a := range acts {
		if a.Label == label {
			return a
		}
	}
	t.Fatalf("no action %q", label)
	return Action{}
}

func TestMachineActions(t *testing.T) {
	a := hostContext(t).Apps[0]
	m := a.Machines[0] // running
	acts := For(Target{Kind: Machine, App: a, Machine: m})
	if d := find(t, acts, "start").Disabled; d != "already running" {
		t.Errorf("start: %q", d)
	}
	stop := find(t, acts, "stop")
	if got := stop.Command(nil).Line(); got != "flk -a minecraft-flk machine stop "+m.ID || stop.Confirm != Ask {
		t.Errorf("stop: %s", got)
	}

	m.State = "stopped" // should run but doesn't
	acts = For(Target{Kind: Machine, App: a, Machine: m})
	if find(t, acts, "start").Disabled != "" || find(t, acts, "restart").Disabled == "" ||
		!strings.Contains(find(t, acts, "stop").Help, "records it as stopped") {
		t.Error("stopped machine that should run")
	}
	m.DesiredState = "stopped"
	if find(t, For(Target{Kind: Machine, App: a, Machine: m}), "stop").Disabled != "already stopped" {
		t.Error("stopped machine")
	}
}

func TestAppActions(t *testing.T) {
	a := hostContext(t).Apps[0]
	acts := For(Target{Kind: App, App: a, StateDir: "/home/u/.local/share/flk"})
	keys := map[string]bool{}
	for _, x := range acts {
		if keys[x.Key] {
			t.Errorf("key %s used twice", x.Key)
		}
		keys[x.Key] = true
	}
	d := find(t, acts, "deploy")
	if d.Disabled != "" || d.Command(nil).Line() != "flk -a minecraft-flk deploy" ||
		d.Command(map[string]string{"image": "ghcr.io/x/y:1"}).Line() != "flk -a minecraft-flk deploy --image ghcr.io/x/y:1" {
		t.Errorf("deploy: %q %s", d.Disabled, d.Command(nil).Line())
	}
	a.ConfigPath = ""
	if find(t, For(Target{Kind: App, App: a}), "deploy").Disabled == "" {
		t.Error("deploy needs config_path")
	}

	// secret values travel on stdin only
	set := find(t, acts, "set secret")
	c := set.Command(map[string]string{"name": "RCON_PASSWORD", "value": "hunter2"})
	if c.Line() != "flk -a minecraft-flk secrets set RCON_PASSWORD=-" || c.Stdin != "hunter2\n" ||
		strings.Contains(c.Line()+c.Warn, "hunter2") {
		t.Errorf("set: %s stdin %q warn %q", c.Line(), c.Stdin, c.Warn)
	}
	c = set.Command(map[string]string{"name": "X", "value": "v", "stage": "later"})
	if c.Line() != "flk -a minecraft-flk secrets set X=- --stage" {
		t.Errorf("staged: %s", c.Line())
	}
	if set.Check(map[string]string{"value": "v"}) != "name is required" {
		t.Error("name is required")
	}

	if got := find(t, acts, "scale").Command(map[string]string{"count": "0"}); got.Line() != "flk -a minecraft-flk scale count 0" ||
		!strings.Contains(got.Warn, "destroyed") {
		t.Errorf("scale: %s %q", got.Line(), got.Warn)
	}
	if find(t, acts, "scale").Check(map[string]string{"count": "two"}) == "" {
		t.Error("scale wants a number")
	}
	if find(t, acts, "resume").Disabled != "nothing to resume" {
		t.Error("resume with everything running")
	}
	des := find(t, acts, "destroy app")
	if des.Confirm != Type || des.TypeName != "minecraft-flk" ||
		des.Command(nil).Line() != "flk apps destroy minecraft-flk --yes" ||
		!strings.Contains(des.Command(nil).Warn, "External volume files are kept") {
		t.Errorf("destroy: %+v %s", des, des.Command(nil).Warn)
	}
	nv := find(t, acts, "new volume").Command(map[string]string{"name": "data", "size": "5", "path": "/big/data.ext4", "from": "/srv/old data"})
	if nv.Line() != "flk -a minecraft-flk volumes create data --size 5 --path /big/data.ext4 --from-dir '/srv/old data'" {
		t.Errorf("create: %s", nv.Line())
	}
}

// Roll back offers kept, healthy, older releases, and passes --no-rollback.
func TestRollback(t *testing.T) {
	a := hostContext(t).Apps[0]
	var rels []flk.Release
	b, _ := fixtures.FS.ReadFile("releases-minecraft-flk.json")
	json.Unmarshal(b, &rels)
	cur := a.Release.Version
	r := find(t, For(Target{Kind: App, App: a}), "roll back") // releases not loaded yet
	if r.Disabled != "" || r.Fields[0].Choices != nil || strings.Join(r.Command(nil).Args, " ") != "-a minecraft-flk releases rollback" {
		t.Errorf("unloaded: %+v %v", r, r.Command(nil).Args)
	}
	// a failed release is never offered
	rels = append(rels, flk.Release{Version: cur + 1, Image: true, Status: "failed", Failure: "check port: nothing on :25565"})
	r = find(t, For(Target{Kind: App, App: a, Releases: rels}), "roll back")
	var want []string
	for i := len(rels) - 1; i >= 0; i-- {
		if rels[i].Image && !rels[i].Failed() && rels[i].Version != cur {
			want = append(want, "v"+strconv.Itoa(rels[i].Version))
		}
	}
	if len(want) == 0 || strings.Join(r.Fields[0].Choices, " ") != strings.Join(want, " ") || r.Confirm != Ask || !r.Long {
		t.Errorf("choices %v, want %v", r.Fields[0].Choices, want)
	}
	c := r.Command(map[string]string{"checks": "leave it"})
	if strings.Join(c.Args, " ") != "-a minecraft-flk releases rollback "+want[0]+" --no-rollback" ||
		!strings.Contains(c.Warn, "Volumes stay as they are") || !strings.Contains(c.Warn, "--no-rollback") {
		t.Errorf("%v / %s", c.Args, c.Warn)
	}
	// stranded on the failed release: current comes first
	stuck := a
	stuck.Machines = append([]flk.Machine(nil), a.Machines...)
	stuck.Machines[0].Release = cur + 1
	r = find(t, For(Target{Kind: App, App: stuck, Releases: rels}), "roll back")
	if r.Fields[0].Choices[0] != "v"+strconv.Itoa(cur) || len(r.Fields[0].Choices) != len(want)+1 {
		t.Errorf("stranded: %v", r.Fields[0].Choices)
	}
	var none []flk.Release
	for _, x := range rels {
		x.Image = x.Version == cur
		none = append(none, x)
	}
	if d := find(t, For(Target{Kind: App, App: a, Releases: none}), "roll back").Disabled; !strings.Contains(d, "keep_releases") {
		t.Errorf("nothing kept: %q", d)
	}
	d := find(t, For(Target{Kind: App, App: a}), "deploy")
	if got := strings.Join(d.Command(map[string]string{"checks": "leave it"}).Args, " "); got != "-a minecraft-flk deploy --no-rollback" {
		t.Errorf("deploy: %s", got)
	}
	if got := strings.Join(d.Command(nil).Args, " "); got != "-a minecraft-flk deploy" {
		t.Errorf("deploy default: %s", got)
	}
}

// Verify and restore as new work while the machine runs (flk 4ff9e9b).
func TestVerifyAndRestoreAs(t *testing.T) {
	hc := hostContext(t)
	a := hc.Apps[0]
	v := a.Volumes[0] // attached to the running machine
	b := []flk.Backup{{File: v.Name + "-20261013T111353Z.ext4", Volume: v.Name, VolumeID: v.ID}, {File: v.Name + "-20261013T100001Z.ext4", Volume: v.Name, VolumeID: v.ID}}
	acts := For(Target{Kind: Volume, App: a, Volume: v, Backups: b, StateDir: hc.Flk.StateDir})
	if find(t, acts, "restore").Disabled == "" {
		t.Error("restore in place needs the machine stopped")
	}
	as := find(t, acts, "restore as new")
	if as.Disabled != "" || as.Confirm != Ask {
		t.Fatalf("%+v", as)
	}
	if got := strings.Join(as.Command(nil).Args, " "); got != "-a minecraft-flk volumes restore world "+b[0].File+" --as world_restored" {
		t.Errorf("%s", got)
	}
	for _, bad := range []string{"world", "world-copy", "World", strings.Repeat("x", 31)} {
		if as.Check(map[string]string{"as": bad}) == "" {
			t.Errorf("%q accepted", bad)
		}
	}
	if restoredName(strings.Repeat("v", 30)) != strings.Repeat("v", 21)+"_restored" {
		t.Error("long names")
	}
	ver := find(t, acts, "verify")
	if got := strings.Join(ver.Command(nil).Args, " "); got != "-a minecraft-flk volumes verify world --backup "+b[0].File {
		t.Errorf("verify default: %s", got)
	}
	for val, want := range map[string]string{"all": "--all", b[1].File: "--backup " + b[1].File} {
		if got := strings.Join(ver.Command(map[string]string{"backup": val}).Args, " "); got != "-a minecraft-flk volumes verify world "+want {
			t.Errorf("verify %q: %s", val, got)
		}
	}
	cp := find(t, acts, "copy")
	if got := strings.Join(cp.Command(map[string]string{"dest": "nas:/b"}).Args, " "); got != "-a minecraft-flk volumes copy world --backup "+b[0].File+" --dest nas:/b" ||
		cp.Confirm != Ask || !strings.Contains(cp.Command(nil).Warn, "backup_copy_to/minecraft-flk/world/") {
		t.Errorf("copy: %s / %s", got, cp.Command(nil).Warn)
	}
	if ver.Confirm != NoConfirm || find(t, For(Target{Kind: Volume, App: a, Volume: v}), "verify").Disabled == "" {
		t.Error("verify only reads; it waits for the backups list")
	}
}

func TestVolumeActions(t *testing.T) {
	a := hostContext(t).Apps[0]
	v := a.Volumes[0] // external, attached to the running machine
	acts := For(Target{Kind: Volume, App: a, Volume: v, StateDir: "/home/u/.local/share/flk"})
	if b := find(t, acts, "back up").Command(nil).Line(); b != "flk -a minecraft-flk volumes backup world" {
		t.Errorf("backup: %s", b)
	}
	if d := find(t, acts, "extend").Disabled; !strings.HasPrefix(d, "machine "+a.Machines[0].ID) {
		t.Errorf("extend while running: %q", d)
	}
	if find(t, acts, "unregister").Disabled == "" || find(t, acts, "destroy with data").Disabled == "" {
		t.Error("attached volumes can't be destroyed")
	}

	a.Machines[0].State = "stopped"
	backups := []flk.Backup{{File: "world-2.ext4", VolumeID: v.ID}, {File: "other.ext4", VolumeID: "vol_x"}, {File: "world-1.ext4", VolumeID: v.ID}}
	acts = For(Target{Kind: Volume, App: a, Volume: v, Backups: backups, StateDir: "/home/u/.local/share/flk"})
	r := find(t, acts, "restore")
	if r.Disabled != "" || strings.Join(r.Fields[0].Choices, " ") != "world-2.ext4 world-1.ext4" || r.Confirm != Type {
		t.Errorf("restore: %+v", r)
	}
	if got := r.Command(nil).Line(); got != "flk -a minecraft-flk volumes restore world world-2.ext4" {
		t.Errorf("restore defaults to the newest: %s", got)
	}
	if got := find(t, acts, "extend").Command(map[string]string{"size": "50"}).Line(); got != "flk -a minecraft-flk volumes extend world --size 50" {
		t.Errorf("extend: %s", got)
	}
	if find(t, For(Target{Kind: Volume, App: a, Volume: v}), "restore").Disabled == "" {
		t.Error("restore before backups load")
	}

	a.Volumes[0].AttachedMachine = ""
	a.Volumes[0].Path = "/home/u/.local/share/flk/apps/minecraft-flk/volumes/world.ext4"
	acts = For(Target{Kind: Volume, App: a, Volume: a.Volumes[0], StateDir: "/home/u/.local/share/flk"})
	if d := find(t, acts, "destroy"); d.Disabled != "" || d.Command(nil).Line() != "flk -a minecraft-flk volumes destroy "+v.ID {
		t.Errorf("destroy: %+v", d)
	}
}

func TestHostActions(t *testing.T) {
	hc := hostContext(t)
	probs := []flk.DoctorCheck{{Label: "port helper", Status: "warn", Hint: "sudo /home/u/flk/setup-host.sh"}}
	acts := For(Target{Kind: Host, Apps: hc.Apps, Problems: probs})
	if find(t, acts, "stop all").Command(nil).Line() != "flk stop-all" || find(t, acts, "resume all").Disabled == "" {
		t.Error("host lifecycle")
	}
	c := find(t, acts, "copy: sudo /home/u/flk/setup-host.sh")
	if c.View != ViewCopy || c.Copy != "sudo /home/u/flk/setup-host.sh" {
		t.Errorf("root step: %+v", c)
	}
}

func TestFix(t *testing.T) {
	hc := hostContext(t)
	id := hc.Apps[0].Machines[0].ID
	for _, c := range []struct{ step, label, line string }{
		{"minecraft-flk: machine " + id + " [mellow] should be running but isn't (it exited, or the host restarted); " +
			"see why: flk logs -i " + id + " --no-tail; bring it back: flk resume",
			"fix: flk -a minecraft-flk resume", "flk -a minecraft-flk resume"},
		{"minecraft-flk: machine " + id + " [m] kept failing; its restart policy gave up after 5 restarts: flk logs -i " +
			id + " --no-tail, fix, then flk machine start " + id,
			"fix: flk -a minecraft-flk machine start " + id, "flk -a minecraft-flk machine start " + id},
		{"minecraft-flk: [[mounts]] source 'world' needs 2 more volumes: flk volumes create world --size 1 (run 2 times)",
			"fix: flk -a minecraft-flk volumes create world --size 1", "flk -a minecraft-flk volumes create world --size 1"},
		{"minecraft-flk: deploy the first release: flk deploy", "fix: flk -a minecraft-flk deploy", "flk -a minecraft-flk deploy"},
		{"minecraft-flk: no machines; flk deploy (or flk scale count 1)", "fix: flk -a minecraft-flk deploy", "flk -a minecraft-flk deploy"},
		{"minecraft-flk: flk doesn't know where minecraft-flk's flk.toml is: run flk launch --no-deploy (or flk deploy) once in its directory",
			"copy: flk launch --no-deploy", ""},
		{"optional: 1 destroyed app still have container images -> flk apps prune", "fix: flk apps prune", "flk apps prune"},
		{"optional: port helper (forwarding [[services.ports]]) -> sudo /home/u/flk/setup-host.sh",
			"copy: sudo /home/u/flk/setup-host.sh", ""},
	} {
		act, ok := Fix(c.step, hc.Apps)
		if !ok || act.Label != c.label {
			t.Errorf("%s\n  got %q %v", c.step, act.Label, ok)
			continue
		}
		if c.line != "" && act.Command(nil).Line() != c.line {
			t.Errorf("%s\n  runs %s", c.step, act.Command(nil).Line())
		}
		if c.line == "" && act.View != ViewCopy {
			t.Errorf("%s: should be copy only", c.step)
		}
	}
	if _, ok := Fix("minecraft-flk: host port tcp/25565 is held by another machine; this one gets it when that stops", hc.Apps); ok {
		t.Error("no command, no fix")
	}
	// a hostile-looking command is never run
	if act, _ := Fix("x: flk machine start $(reboot)", hc.Apps); act.View != ViewCopy {
		t.Errorf("ran %+v", act)
	}
}

// flk 821f84b: a machine left on a failed release; roll back is the fix.
func TestFixFailedRelease(t *testing.T) {
	apps := hostContext(t).Apps
	step := apps[0].Name + ": machine 225d58f615e7e6 [mellow-aurora-7882] is on v10, which failed its health checks (left by --no-rollback): " +
		"see flk logs -i 225d58f615e7e6 --no-tail; then flk releases rollback, or fix and flk deploy"
	f, ok := Fix(step, apps)
	if !ok || f.Label != "fix: flk -a minecraft-flk releases rollback" || f.Confirm != Ask || !f.Long {
		t.Errorf("%+v", f)
	}
	if f, ok := Fix(strings.Replace(step, "flk releases rollback,", "flk releases rollback v2,", 1), apps); !ok || f.Label != "fix: flk -a minecraft-flk releases rollback v2" {
		t.Errorf("with a version: %+v", f)
	}
	if _, ok := Fix(apps[0].Name+": optional: flk.toml: unknown key kill_timout (did you mean kill_timeout?); flk ignores it", apps); ok {
		t.Error("a config warning has no command to run")
	}
}

func TestArgTokens(t *testing.T) {
	for in, want := range map[string]string{
		"ID...":               "ID...",
		"LOCAL[:REMOTE] [ID]": "LOCAL[:REMOTE]|[ID]",
		"ID|NAME [BACKUP]":    "ID|NAME|[BACKUP]",
		"[ID|NAME...]":        "[ID|NAME...]",
		"":                    "",
	} {
		if got := strings.Join(argTokens(in), "|"); got != want {
			t.Errorf("%q: %q", in, got)
		}
	}
	if f, m := optionSwitch([]string{"-i", "--instance ID"}); f != "--instance" || m != "ID" {
		t.Errorf("%s %s", f, m)
	}
}

// The palette covers flk's whole command table and builds argv from forms.
func TestPalette(t *testing.T) {
	b, _ := fixtures.FS.ReadFile("help-all.json")
	var h flk.Help
	json.Unmarshal(b, &h)
	entries := Palette(h, "minecraft-flk", false)
	byName := map[string]Entry{}
	for _, e := range entries {
		byName[e.Name] = e
	}
	for _, n := range []string{"machine start", "volumes backup", "volumes restore", "logs", "proxy", "ssh console", "apps destroy"} {
		if _, ok := byName[n]; !ok {
			t.Errorf("no %s", n)
		}
	}
	if _, ok := byName["machine"]; ok {
		t.Error("parents with subcommands aren't entries")
	}
	run := func(name string, vals map[string]string) string { return byName[name].Action.Command(vals).Line() }
	if got := run("logs", map[string]string{"--instance": "225d", "--lines": "5", "--no-tail": "yes"}); got != "flk -a minecraft-flk logs --instance 225d --lines 5 --no-tail" {
		t.Errorf("logs: %s", got)
	}
	if got := run("machine start", map[string]string{"arg0": "a b"}); got != "flk -a minecraft-flk machine start a b" {
		t.Errorf("variadic: %s", got)
	}
	if got := run("volumes restore", map[string]string{"arg0": "world"}); got != "flk -a minecraft-flk volumes restore world" {
		t.Errorf("restore: %s", got)
	}
	if c := byName["volumes restore"].Action.Command(map[string]string{"arg0": "world"}); c.TypeName != "world" {
		t.Errorf("restore confirm: %+v", c)
	}
	if got := run("doctor", nil); got != "flk doctor" || byName["doctor"].Action.Confirm != NoConfirm {
		t.Errorf("doctor: %s", got)
	}
	if got := run("resume", nil); got != "flk resume" {
		t.Errorf("resume scopes to every app by default: %s", got)
	}
	if c := byName["console"].Action.Command(map[string]string{"--send": "save-all"}); c.Interactive || c.Line() != "flk -a minecraft-flk console --send save-all" {
		t.Errorf("console --send: %+v", c)
	}
	if !byName["console"].Action.Command(nil).Interactive {
		t.Error("console attaches")
	}
	if byName["launch"].Action.Disabled == "" || byName["secrets set"].Action.Disabled == "" {
		t.Error("launch and secrets set don't run from lazyflk")
	}
	if Palette(h, "", true)[0].Action.Disabled != "" { // context: read-only is fine
		t.Error("read-only commands stay available")
	}
}
