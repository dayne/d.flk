package providers

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"lazyflk/fixtures"
	"lazyflk/internal/actions"
	"lazyflk/internal/flk"
)

func demo() (Host, Env) {
	f := &Fake{FS: fixtures.FS, Files: DemoFiles}
	var hc flk.HostContext
	b, _ := fixtures.FS.ReadFile("context-all.json")
	json.Unmarshal(b, &hc)
	return f.For, Env{StateDir: hc.Flk.StateDir, MountDirs: hc.MountDirs}
}

func joined(it Item) string { return strings.Join(it.Lines, "\n") }

func TestStorage(t *testing.T) {
	h, env := demo()
	items, err := Storage{}.Load(context.Background(), h, env)
	if err != nil || len(items) != 3 {
		t.Fatalf("%d items, %v", len(items), err)
	}
	mc := items[1]
	if mc.Label != "/data/minecraft 66%" || mc.State != OK || !strings.Contains(joined(mc), "holds     /data/minecraft/flk") {
		t.Errorf("minecraft disk: %+v", mc)
	}
	// the LVM chain, and room left in the volume group
	if s := joined(mc); !strings.Contains(s, "lvm") || !strings.Contains(s, "WD_BLACK") || !strings.Contains(s, "isn't in any logical volume yet") {
		t.Errorf("devices:\n%s", s)
	}
	if len(mc.Actions) != 1 || mc.Actions[0].View != actions.ViewCopy || !strings.HasPrefix(mc.Actions[0].Copy, "sudo lvextend -r -L +10G /dev/mapper/") {
		t.Errorf("grow: %+v", mc.Actions)
	}
}

// An LVM snapshot shows under its origin (lsblk-snapshot.json: the
// reference host on 2026-10-13 with one).
func TestStorageSnapshot(t *testing.T) {
	files := map[string]string{}
	for k, v := range DemoFiles {
		if v == "lsblk.json" {
			v = "lsblk-snapshot.json"
		}
		files[k] = v
	}
	_, env := demo()
	items, err := Storage{}.Load(context.Background(), (&Fake{FS: fixtures.FS, Files: files}).For, env)
	if err != nil {
		t.Fatal(err)
	}
	var all []string
	for _, it := range items {
		all = append(all, joined(it))
	}
	if s := strings.Join(all, "\n"); !strings.Contains(s, "snapshot /dev/mapper/ubuntu--vg-mc--data--pre--edit--2159--20261012 (30G copy-on-write space)") {
		t.Errorf("no snapshot:\n%s", s)
	}
}

func TestPodman(t *testing.T) {
	h, env := demo()
	items, err := Podman{}.Load(context.Background(), h, env)
	if err != nil {
		t.Fatal(err)
	}
	// the fixture's leftover build container (podman-ps.json, State storage)
	var cs []podmanContainer
	raw, _ := fixtures.FS.ReadFile("podman-ps.json")
	json.Unmarshal(raw, &cs)
	var bc *podmanContainer
	for i := range cs {
		if cs[i].State == "storage" {
			bc = &cs[i]
		}
	}
	if bc != nil && time.Since(time.Unix(bc.Created, 0)) > time.Hour { // an old one is flagged
		var b Item
		for _, it := range items {
			if it.Key == "podman/c/"+bc.ID {
				b = it
			}
		}
		if b.Label != "▢ "+bc.Names[0]+" (build)" || b.State != Warn || len(b.Problems) != 1 || b.Fix == nil ||
			b.Fix.Command(nil).Line() != "buildah rm "+bc.ID[:12] || b.Fix.Confirm != actions.Type || b.Fix.TypeName != bc.Names[0] {
			t.Errorf("build container: %+v", b)
		}
	}
	var names []string
	for _, it := range items {
		names = append(names, it.Label)
	}
	all := strings.Join(names, "\n")
	if strings.Contains(all, "flk.local") || !strings.Contains(all, "flk images: host Images tab") || !strings.Contains(all, "itzg/minecraft-server:latest") {
		t.Errorf("images:\n%s", all)
	}
	if shortRef("docker.io/library/alpine:3.20") != "alpine:3.20" || shortRef("localhost/x:1") != "localhost/x:1" {
		t.Error("shortRef")
	}
}

// A long-running test container gets flagged, with stop as its fix.
func TestPodmanTestContainer(t *testing.T) {
	now := time.Date(2026, 10, 13, 0, 0, 0, 0, time.UTC)
	it := containerItem(podmanContainer{ID: "0123456789abcdef", Names: []string{"mc-run-test"}, Image: "docker.io/itzg/minecraft-server",
		State: "running", Status: "Up 3 days", StartedAt: now.Add(-72 * time.Hour).Unix()}, now, false)
	if it.State != Warn || len(it.Problems) != 1 || it.Fix == nil || it.Fix.Command(nil).Line() != "podman stop mc-run-test" || it.Logs == nil {
		t.Errorf("%+v", it)
	}
	it = containerItem(podmanContainer{ID: "0123456789abcdef", Names: []string{"web"}, State: "exited"}, now, false)
	// with buildah, a build container goes the owner's way
	b := containerItem(podmanContainer{ID: "f7cd17e4bfbcde38", Names: []string{"ruby-working-container"}, State: "storage",
		Created: now.Add(-2 * time.Hour).Unix()}, now, true)
	if b.Fix == nil || b.Fix.Command(nil).Line() != "buildah rm f7cd17e4bfbc" {
		t.Errorf("buildah: %+v", b.Fix)
	}
	// a build that's running now has one too: not a problem
	b = containerItem(podmanContainer{ID: "f7cd17e4bfbcde38", Names: []string{"ruby-working-container"}, State: "storage",
		Created: now.Add(-5 * time.Minute).Unix()}, now, true)
	if b.State != Off || len(b.Problems) != 0 || b.Fix != nil || b.Label != "▢ ruby-working-container (building)" {
		t.Errorf("fresh build container: %+v", b)
	}
	if it.State != Off || it.Actions[0].Label != "remove" || it.Actions[0].TypeName != "web" {
		t.Errorf("exited: %+v", it)
	}
}

func TestServices(t *testing.T) {
	h, env := demo()
	items, err := Services{}.Load(context.Background(), h, env)
	if err != nil || len(items) != 5 {
		t.Fatalf("%d items, %v", len(items), err)
	}
	if items[0].Label != "● flk-net" || !strings.Contains(joined(items[0]), "one of flk's units") {
		t.Errorf("flk-net: %+v", items[0])
	}
	if items[2].Label != "● ssh" || items[2].Logs == nil || items[2].Logs.Line() != "journalctl -u ssh.service -f -n 200 --no-pager -o short-iso" {
		t.Errorf("ssh: %+v", items[2])
	}
	for _, a := range items[2].Actions[1:] {
		if a.View != actions.ViewCopy || !strings.HasPrefix(a.Copy, "sudo systemctl ") {
			t.Errorf("root steps are copied: %+v", a)
		}
	}
	if strings.Contains(joined(items[2]), "systemd-journal") {
		t.Error("the fixture's user is in adm: no journal note")
	}

	failed := unitItem("x.service", map[string]string{"Id": "x.service", "LoadState": "loaded", "ActiveState": "failed", "SubState": "failed", "Result": "exit-code"}, false, "", "")
	if failed.State != Bad || len(failed.Problems) != 1 {
		t.Errorf("failed: %+v", failed)
	}
	if canReadJournal("dayne sudo") || !canReadJournal("dayne adm") {
		t.Error("journal groups")
	}

	pins := filepath.Join(t.TempDir(), "pins")
	os.WriteFile(pins, []byte("# mine\nnginx\ncron.service\n"), 0o644)
	if got, ok := (Services{PinsFile: pins}).pins(); !ok || strings.Join(got, " ") != "nginx.service cron.service" {
		t.Errorf("pins %v", got)
	}
}

func TestAppActions(t *testing.T) {
	list, err := ParseAppActions(`
# Minecraft's own commands
[flk]
ignored = "x"

[actions]
save = "flk -a {app} console {machine} --send save-all --wait-log 'Saved the game'"  # trailing comment

[actions.say]
run  = 'flk -a {app} console {machine} --send "say {input}"'
help = "broadcast a message"
`)
	if err != nil || len(list) != 2 || list[1].Help != "broadcast a message" || !strings.HasSuffix(list[0].Run, "'Saved the game'") {
		t.Fatalf("%+v %v", list, err)
	}
	a := flk.App{Name: "minecraft-flk", Machines: []flk.Machine{{ID: "225d58f615e7e6", Name: "mellow"}},
		Volumes: []flk.Volume{{Name: "world", Path: "/data/minecraft/flk/world.ext4"}}}
	acts := AppActionItems(list, a, nil, "/home/u/minecraft.flk")
	c := acts[0].Command(nil)
	if c.Program != "sh" || c.Args[1] != "cd '/home/u/minecraft.flk' && flk -a minecraft-flk console 225d58f615e7e6 --send save-all --wait-log 'Saved the game'" {
		t.Errorf("save: %q", c.Args)
	}
	say := acts[1]
	if len(say.Fields) != 1 || say.Key != "2" {
		t.Errorf("say: %+v", say)
	}
	if why := say.Check(map[string]string{"input": "two\nlines"}); why == "" {
		t.Error("input is one line")
	}
	if c := say.Command(map[string]string{"input": "don't $(reboot)"}); !strings.HasSuffix(c.Args[1], `--send "say ${1}"`) ||
		len(c.Args) != 4 || c.Args[2] != "lazyflk-input" || c.Args[3] != "don't $(reboot)" {
		t.Errorf("say: %q", c.Args)
	}
	if line, why := Expand("cp {volume.world} /b/ && {nope}", a, nil, "/d", ""); why == "" || !strings.Contains(line, "/data/minecraft/flk/world.ext4") {
		t.Errorf("%s / %s", line, why)
	}
	if _, why := Expand("x {app}", flk.App{Name: "a b"}, nil, "/d", ""); why == "" {
		t.Error("unsafe names are refused")
	}
	// root steps are copied, never run
	root := AppActionItems([]AppAction{{Name: "snap", Run: "sudo bin/mc-snap status"}, {Name: "x", Run: "true && sudo rm {input}"}},
		a, nil, "/home/u/mc")
	if root[0].View != actions.ViewCopy || root[0].Copy != "cd /home/u/mc && sudo bin/mc-snap status" || root[1].Disabled == "" {
		t.Errorf("sudo: %+v", root)
	}
	if _, err := ParseAppActions("[actions]\nbad\n"); err == nil {
		t.Error("bad line")
	}
}

// Typed input reaches the command as text, whatever it holds and wherever
// {input} stands: unquoted, in '...' or in "...".
func TestInputIsData(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "show"), []byte("#!/bin/sh\nfor a; do printf '[%s]' \"$a\"; done\n"), 0o755)
	a := flk.App{Name: "x", Machines: []flk.Machine{{ID: "m1"}}}
	for _, input := range []string{"don't", `say "hi" $HOME $(touch pwned) ` + "`id`" + ` ; rm -rf / & | < > \\ (x) {input}`, "  two  spaces "} {
		for run, want := range map[string]string{
			"./show say {input}":         "[say][" + input + "]",
			"./show 'say {input}!'":      "[say " + input + "!]",
			`./show "say {input} \"q\""`: "[say " + input + ` "q"]`,
			`./show "it's" '{input}'`:    "[it's][" + input + "]",
		} {
			acts := AppActionItems([]AppAction{{Name: "t", Run: run}}, a, nil, dir)
			if why := acts[0].Check(map[string]string{"input": input}); why != "" {
				t.Fatalf("%s: %s", run, why)
			}
			c := acts[0].Command(map[string]string{"input": input})
			out, err := exec.Command(c.Program, c.Args...).CombinedOutput()
			if err != nil || string(out) != want {
				t.Errorf("%s with %q: got %q (%v), want %q\n  line: %s", run, input, out, err, want, c.Line())
			}
		}
	}
	if _, err := os.Stat(filepath.Join(dir, "pwned")); err == nil {
		t.Error("input ran as code")
	}
}

// Every host tool's fixture is used by some provider.
func TestDemoFilesExist(t *testing.T) {
	for cmd, name := range DemoFiles {
		if _, err := fixtures.FS.ReadFile(name); err != nil {
			t.Errorf("%s: %s missing", cmd, name)
		}
	}
	h, _ := demo()
	if out, err := h("journalctl").Run(context.Background(), "-u", "chrony.service", "-n", "40"); err != nil || len(out) == 0 {
		t.Errorf("journal: %v", err)
	}
	s, _ := h("podman").Stream(context.Background(), "", "rm", "x")
	if l := <-s.Lines; !strings.Contains(l.Text, "demo mode: podman was not run") {
		t.Errorf("demo action: %q", l.Text)
	}
}
