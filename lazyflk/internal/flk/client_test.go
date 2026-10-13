package flk

import (
	"context"
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"lazyflk/fixtures"
)

func fakeClient() (*Client, *Fake) {
	f := NewFake(fixtures.FS)
	return New(f), f
}

// Every JSON fixture decodes into its type, with the values flk printed.
func TestDecodeFixtures(t *testing.T) {
	c, _ := fakeClient()
	ctx := context.Background()
	const app, id = "minecraft-flk", "225d58f615e7e6"

	hc, err := c.HostContext(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if hc.Flk.Version != "0.1.0" || !hc.Host.OK || hc.Host.LanIP != "10.47.11.116" || !hc.Host.BootService {
		t.Errorf("host context: %+v", hc)
	}
	if len(hc.Apps) != 1 || hc.Apps[0].Name != app || hc.Apps[0].Release.Version != 8 || hc.Apps[0].Scale != nil || hc.Apps[0].ConfigPath != "/home/dayne/minecraft.flk/flk.toml" {
		t.Fatalf("apps: %+v", hc.Apps)
	}
	a := hc.Apps[0]
	if m := a.Machines[0]; m.ID != id || !m.Started() || m.ShouldRun() || m.MemoryMB != 11264 || len(m.Ports) != 2 ||
		m.Restart == nil || m.Restart.Policy != "on-failure" || m.Restarts != nil {
		t.Errorf("machine: %+v", m)
	}
	if len(a.Ports.Active) != 2 || a.Ports.Active[1].Address != "10.47.11.116:19132" || len(hc.MountDirs) != 2 || len(hc.NextSteps) != 0 {
		t.Errorf("ports %+v, mount dirs %v", a.Ports, hc.MountDirs)
	}

	ac, err := c.AppContext(ctx, app)
	if err != nil || ac.App == nil || ac.App.Name != app || len(ac.NextSteps) != 1 {
		t.Errorf("app context: %+v, %v", ac, err)
	}
	doc, err := c.Doctor(ctx)
	if err != nil || !doc.OK || len(doc.Checks) != 14 || doc.Checks[0].Status != "pass" {
		t.Errorf("doctor: %+v, %v", doc, err)
	}
	apps, err := c.Apps(ctx)
	if err != nil || len(apps) != 1 || apps[0].Started != 1 || apps[0].ConfigPath == "" {
		t.Errorf("apps: %+v, %v", apps, err)
	}
	pl, err := c.Ports(ctx)
	if err != nil || !pl.HelperInstalled || pl.MinPort != 1024 || len(pl.Active) != 2 {
		t.Errorf("ports: %+v, %v", pl, err)
	}
	st, err := c.Status(ctx, app)
	if err != nil || st.App.Name != app || st.App.ConfigPath == "" || len(st.Machines) != 1 {
		t.Errorf("status: %+v, %v", st, err)
	}
	rels, err := c.Releases(ctx, app)
	if err != nil || len(rels) != 8 || rels[7].Tag != "flk.local/minecraft-flk:v8" {
		t.Errorf("releases: %+v, %v", rels, err)
	}
	vols, err := c.Volumes(ctx, app)
	if err != nil || len(vols) != 1 || vols[0].SizeGB != 40 || vols[0].AttachedMachine != id {
		t.Errorf("volumes: %+v, %v", vols, err)
	}
	secs, err := c.Secrets(ctx, app)
	if err != nil || len(secs) != 0 {
		t.Errorf("secrets: %+v, %v", secs, err)
	}
	rec, err := c.MachineStatus(ctx, app, "225d")
	if err != nil || rec.ID != id || rec.Config.Env["MC_HEAP"] != "8G" || rec.Config.KillTimeout != 120 || rec.Config.Restart.Retries != 1 {
		t.Errorf("machine status: %+v, %v", rec, err)
	}
	help, err := c.Help(ctx)
	if err != nil || len(help.Commands) == 0 || len(help.Topics) != 6 {
		t.Fatalf("help: %v", err)
	}
	var console *Command
	for i := range help.Commands {
		if help.Commands[i].Name == "console" {
			console = &help.Commands[i]
		}
	}
	if console == nil || console.Blocks == "" || len(console.Options) != 3 || console.Options[0].Switches[0] != "--send TEXT" {
		t.Errorf("console command: %+v", console)
	}
	logs, err := c.Logs(ctx, app, "", 40)
	if err != nil || !strings.Contains(logs, "Started Geyser on UDP port 19132") {
		t.Errorf("logs: %q, %v", logs, err)
	}
}

// Every fixture file is reachable through some command.
func TestEveryFixtureServed(t *testing.T) {
	c, f := fakeClient()
	ctx := context.Background()
	c.HostContext(ctx)
	c.Run(ctx, "context", "--all")
	c.Run(ctx, "context")
	c.AppContext(ctx, "minecraft-flk")
	c.Doctor(ctx)
	c.Apps(ctx)
	c.Ports(ctx)
	c.Status(ctx, "minecraft-flk")
	c.Releases(ctx, "minecraft-flk")
	c.Volumes(ctx, "minecraft-flk")
	c.Secrets(ctx, "minecraft-flk")
	c.MachineStatus(ctx, "minecraft-flk", "mellow-aurora-7882")
	c.Help(ctx)
	c.Logs(ctx, "minecraft-flk", "", 40)
	c.Run(ctx, "-a", "minecraft-flk", "config", "show")
	for _, topic := range []string{"cheatsheet", "install", "first-app", "operate", "troubleshoot", "uninstall"} {
		if out, err := c.Run(ctx, "help", topic); err != nil || len(out) == 0 {
			t.Errorf("help %s: %v", topic, err)
		}
	}
	if b, err := c.Backups(ctx, "minecraft-flk"); err != nil || b == nil || len(b) != 0 {
		t.Errorf("backups: %v %v", b, err)
	}

	served := map[string]bool{}
	for _, args := range f.Calls() {
		name, ok := fixtureFor(args)
		if !ok {
			t.Errorf("no fixture for %v", args)
		}
		served[name] = true
	}
	files, _ := fs.Glob(fixtures.FS, "*.*")
	for _, name := range files {
		// df.txt is host.DF's, not flk's; backups-sample.json is decoded below
		if !served[name] && name != "df.txt" && name != "backups-sample.json" {
			t.Errorf("fixture %s is never served", name)
		}
	}
}

func TestFakeRecordsCallsAndFailsLikeFlk(t *testing.T) {
	c, f := fakeClient()
	ctx := context.Background()
	c.Status(ctx, "minecraft-flk")
	_, err := c.Status(ctx, "flkt-nope")
	if err == nil || !strings.HasPrefix(err.Error(), "Error: demo mode has no captured output for: flk -a flkt-nope status --json") {
		t.Errorf("unknown app: %v", err)
	}
	if _, err := c.MachineStatus(ctx, "minecraft-flk", "ffff"); err == nil {
		t.Error("machine status for an unknown ID should fail")
	}
	if _, err := c.Run(ctx, "logs", "-f"); err == nil {
		t.Error("follow has no fixture")
	}
	want := [][]string{
		{"-a", "minecraft-flk", "status", "--json"},
		{"-a", "flkt-nope", "status", "--json"},
		{"-a", "minecraft-flk", "machine", "status", "ffff"},
		{"logs", "-f"},
	}
	if got := f.Calls(); !reflect.DeepEqual(got, want) {
		t.Errorf("calls:\n got %v\nwant %v", got, want)
	}
}

func TestCommandLine(t *testing.T) {
	got := CommandLine("-a", "minecraft-flk", "secrets", "set", "MOTD=it's on", "")
	want := `flk -a minecraft-flk secrets set 'MOTD=it'\''s on' ''`
	if got != want {
		t.Errorf("got %s\nwant %s", got, want)
	}
}

// A stand-in flk script: prints its argv and NO_COLOR, fails on "fail",
// hangs on "hang".
func TestExec(t *testing.T) {
	script := filepath.Join(t.TempDir(), "flk")
	os.WriteFile(script, []byte(`#!/bin/sh
case "$1" in
  fail) echo "Error: no such app 'x' (see: flk apps list)" >&2; exit 1 ;;
  hang) exec sleep 10 ;;
esac
echo "$* NO_COLOR=$NO_COLOR"
`), 0o755)
	c := New(Exec{Path: script})
	ctx := context.Background()

	out, err := c.Run(ctx, "apps", "list", "--json")
	if err != nil || string(out) != "apps list --json NO_COLOR=1\n" {
		t.Errorf("run: %q, %v", out, err)
	}
	_, err = c.Run(ctx, "fail")
	var fe *Error
	if !errors.As(err, &fe) || err.Error() != "Error: no such app 'x' (see: flk apps list)" {
		t.Errorf("fail: %v", err)
	}
	c.Timeout = 100 * time.Millisecond
	start := time.Now()
	if _, err = c.Run(ctx, "hang"); err == nil || !strings.Contains(err.Error(), "timed out") {
		t.Errorf("hang: %v", err)
	}
	if time.Since(start) > 5*time.Second {
		t.Error("timeout didn't stop flk")
	}
}

func TestFindFlk(t *testing.T) {
	dir := t.TempDir()
	script := filepath.Join(dir, "flk")
	os.WriteFile(script, []byte("#!/bin/sh\n"), 0o755)
	t.Setenv("LAZYFLK_FLK", "")
	t.Setenv("PATH", dir)
	if p, err := FindFlk(""); err != nil || p != script {
		t.Errorf("PATH: %s, %v", p, err)
	}
	t.Setenv("LAZYFLK_FLK", "/nonexistent/flk")
	if _, err := FindFlk(""); err == nil {
		t.Error("LAZYFLK_FLK should win over PATH")
	}
	if p, err := FindFlk(script); err != nil || p != script {
		t.Errorf("--flk: %s, %v", p, err)
	}
}

// Real backups (from a test app): newest first, every field decoded.
func TestBackupsSample(t *testing.T) {
	b, _ := fixtures.FS.ReadFile("backups-sample.json")
	var got []Backup
	if err := json.Unmarshal(b, &got); err != nil || len(got) != 2 {
		t.Fatalf("%v %d", err, len(got))
	}
	s, o := got[0], got[1]
	if s.Mode != "stop" || s.Check != "clean" || s.Release != 1 || s.Machine == "" || s.BytesUsed == 0 ||
		s.Seconds == 0 || s.VolumeID == "" || s.Volume != "world" || s.File == "" || s.CreatedAt <= o.CreatedAt {
		t.Errorf("stop-mode backup: %+v", s)
	}
	if o.Mode != "offline" {
		t.Errorf("offline backup: %+v", o)
	}
}
