package ui

import (
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"

	"lazyflk/internal/flk"
)

// G5: after the first full load, polling skips the host checks, and host
// health (with its next_steps) comes from doctor.
func TestQuickPolling(t *testing.T) {
	m := demoModel(t, 80, 24)
	if !m.quick() {
		t.Fatal("the fixtures' flk has a schema: polls should be quick")
	}
	send(m, tickMsg{})
	calls := fake(m).Calls()
	if got := strings.Join(calls[len(calls)-1], " "); !strings.Contains(strings.Join(flatten(calls), "\n"), "context --all --json --no-host") {
		t.Errorf("no quick poll, last call %s", got)
	}
	if !m.hc.Host.OK || !m.hc.Host.BootService || len(m.hc.Host.Services) != 2 || m.hc.Host.LanIP != "10.47.11.116" {
		t.Errorf("merged host: %+v", m.hc.Host)
	}

	// a failing check from doctor becomes a host problem and a next step
	d, _ := m.opt.Client.Doctor(t.Context())
	d.Checks = append(d.Checks, flk.DoctorCheck{Label: "bridge flkbr0", Status: "fail", Hint: "sudo /x/setup-host.sh"})
	m.cache[m.doctorSource().cmd].val = d
	send(m, fetchedMsg{key: m.doctorSource().cmd, val: d})
	if m.hc.Host.OK || len(m.hc.NextSteps) != 1 || m.hc.NextSteps[0] != "fix: bridge flkbr0 -> sudo /x/setup-host.sh" {
		t.Errorf("host %+v steps %v", m.hc.Host, m.hc.NextSteps)
	}
	if s := screen(m); !strings.Contains(s, "host NOT ready") || !strings.Contains(s, "fix: bridge flkbr0") {
		t.Errorf("screen:\n%s", s)
	}
}

func flatten(calls [][]string) []string {
	var out []string
	for _, c := range calls {
		out = append(out, strings.Join(c, " "))
	}
	return out
}

// G6: a newer schema warns; an older flk (no schema) polls the full way.
func TestSchema(t *testing.T) {
	m := demoModel(t, 80, 24)
	withState(t, m, func(hc *flk.HostContext) { hc.Schema = 2 })
	if s := screen(m); !strings.Contains(s, "flk's JSON is schema 2, this lazyflk knows 1") {
		t.Errorf("no warning:\n%s", s)
	}
	withState(t, m, func(hc *flk.HostContext) { hc.Schema = 0 })
	if m.quick() {
		t.Error("an flk without a schema has no --no-host")
	}
}

func TestServiceLines(t *testing.T) {
	no := false
	got := ansi.Strip(strings.Join(serviceLines([]flk.Service{
		{Unit: "flk-net.service", Installed: true, Enabled: &no, Active: "failed", Sub: "failed", Result: "exit-code"},
		{Unit: "flk-machines.service"},
	}, 76), "\n"))
	for _, want := range []string{"✘ flk-net.service  failed (failed)", "disabled (won't run at boot)", "result exit-code",
		"journalctl -u flk-net.service -b", "! flk-machines.service  not installed"} {
		if !strings.Contains(got, want) {
			t.Errorf("missing %q in\n%s", want, got)
		}
	}
	if !strings.Contains(strings.Join(serviceLines(nil, 76), " "), "needs flk with G9") {
		t.Error("an older flk")
	}
}

// Two tags of one image count once; orphans point at apps prune.
func TestImageLines(t *testing.T) {
	r := 3
	got := ansi.Strip(strings.Join(imageLines([]flk.Image{
		{Tag: "v3", ID: "a", SizeBytes: 1 << 30, App: "x", Release: &r, Current: true, Running: true},
		{Tag: "v2", ID: "a", SizeBytes: 1 << 30, App: "x"},
		{Tag: "v1", ID: "b", SizeBytes: 1 << 30, App: "gone", Orphan: true},
	}), "\n"))
	for _, want := range []string{"v2     1.0G  same image as v3", "gone  app gone", "2.0G in 2 images", "1.0G belong to apps that are gone"} {
		if !strings.Contains(got, want) {
			t.Errorf("missing %q in\n%s", want, got)
		}
	}
	if strings.Index(got, "gone  app gone") < strings.Index(got, "x") {
		t.Error("orphans go last")
	}
}
