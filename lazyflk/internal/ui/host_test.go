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
	var texts []string
	for _, it := range m.attnItems() {
		texts = append(texts, it.text)
	}
	if !strings.Contains(strings.Join(texts, "\n"), "flk's JSON is schema 2, this lazyflk knows 1") {
		t.Errorf("no warning: %v", texts)
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

// A port bound to one address shows as flk shows it, and a machine port
// forwarded on two addresses lists both.
func TestBoundPorts(t *testing.T) {
	m := demoModel(t, 160, 48)
	b1, b2 := "10.47.11.3", "10.47.11.4"
	withState(t, m, func(hc *flk.HostContext) {
		hc.Host.Address = b1
		p := hc.Apps[0].Ports.Active[0]
		p.Bind, p.Address = &b1, b1+":25565"
		q := p
		q.Bind, q.Address = &b2, b2+":25565"
		hc.Apps[0].Ports.Active = append([]flk.Port{p, q}, hc.Apps[0].Ports.Active[1:]...)
	})
	goTo(m, kindMachine)
	s := screen(m)
	for _, want := range []string{"10.47.11.3: tcp/25565 udp/19132", "tcp/25565 → 10.47.11.3:25565, 10.47.11.4:25565", "address 10.47.11.3 (LAN 10.47.11.116)"} {
		if !strings.Contains(s, want) {
			t.Errorf("missing %q:\n%s", want, s)
		}
	}
}
