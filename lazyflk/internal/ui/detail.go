package ui

import (
	"fmt"
	"lazyflk/internal/actions"
	"strings"
	"time"

	"lazyflk/internal/flk"
)

// detail returns the right pane's title and Overview lines for a node.
func (m *Model) detail(n node) (string, []string) {
	switch n.kind {
	case kindProvider:
		return m.providerDetail(n, 1<<20)
	case kindApp:
		a := m.apps[n.app]
		return a.Name, m.appOverview(a)
	case kindMachine:
		a := m.apps[n.app]
		mc := a.Machines[n.machine]
		return a.Name + " / " + or(mc.Name, mc.ID), m.machineOverview(a, mc)
	case kindVolume:
		a := m.apps[n.app]
		v := a.Volumes[n.volume]
		return a.Name + " / volume " + v.Name, m.volumeOverview(a, v)
	case kindPorts:
		a := m.apps[n.app]
		return a.Name + " / ports", portLines(a.Ports, "")
	case kindHost:
		return "Host", m.hostOverview()
	}
	return "", nil
}

func (m *Model) appOverview(a flk.App) []string {
	var out []string
	if !a.Registered {
		out = append(out, styleBad.Render("not registered")+" (flk launch --no-deploy)")
	}
	if r := a.Release; r != nil {
		out = append(out, fmt.Sprintf("%s v%d (%d kept) · %s", styleLabel.Render("release"),
			r.Version, a.Releases, when(r.CreatedAt)))
	} else {
		out = append(out, styleLabel.Render("release")+" none yet: flk deploy")
	}
	if a.Scale != nil {
		out = append(out, fmt.Sprintf("%s %d", styleLabel.Render("scale"), *a.Scale))
	}
	out = append(out, "")
	if len(a.Machines) == 0 {
		out = append(out, styleLabel.Render("machines")+" none")
	}
	for _, mc := range a.Machines {
		out = append(out,
			fmt.Sprintf("%s %s %s %s %s", styleLabel.Render("machine"), mc.ID, machineIcon(mc), stateText(mc), mc.IP),
			fmt.Sprintf("  %s · %s · v%d", or(mc.Name, "-"), size(mc.CPUs, mc.MemoryMB), mc.Release))
		if live := m.liveShort(mc.ID); live != "" {
			out = append(out, styleDim.Render("  "+strings.TrimPrefix(live, " · ")))
		}
	}
	out = append(out, "")
	out = append(out, portLines(a.Ports, "ports  ")...)
	for _, v := range a.Volumes {
		out = append(out, fmt.Sprintf("%s %s %dGB%s", styleLabel.Render("volume"),
			v.Name, v.SizeGB, externalNote(v, m.hc.Flk.StateDir)), "  "+v.Path)
	}
	if len(a.Secrets) > 0 {
		out = append(out, styleLabel.Render("secrets")+" "+strings.Join(a.Secrets, " "))
	}
	if probs := appProblems(a, m.hc.NextSteps); len(probs) > 0 {
		out = append(out, "")
		for _, p := range probs {
			out = append(out, styleBad.Render("! ")+p)
		}
	}
	return out
}

func (m *Model) machineOverview(a flk.App, mc flk.Machine) []string {
	out := []string{
		field("id", mc.ID),
		field("name", or(mc.Name, "-")),
		field("state", machineIcon(mc)+" "+stateText(mc)),
		field("release", fmt.Sprintf("v%d", mc.Release)),
		field("ip", mc.IP+portSuffix(mc.InternalPort)),
		field("size", size(mc.CPUs, mc.MemoryMB)),
	}
	out = append(out, m.liveLines(mc)...)
	if r := mc.Restart; r != nil {
		out = append(out, field("restart", restartText(*r, mc.Restarts)))
	}
	for i, p := range mc.Ports {
		label := ""
		if i == 0 {
			label = "ports"
		}
		out = append(out, field(label, fmt.Sprintf("%s/%d → %s", p.Proto, p.Port, forwardedTo(a.Ports, mc, p))))
	}
	for i, mt := range mc.Volumes {
		label := ""
		if i == 0 {
			label = "volumes"
		}
		name := mt.Volume
		for _, v := range a.Volumes {
			if v.ID == mt.Volume {
				name = v.Name
			}
		}
		out = append(out, field(label, name+" → "+mt.Destination))
	}
	return append(out, field("created", when(mc.CreatedAt)), field("updated", when(mc.UpdatedAt)))
}

// forwardedTo says where a machine port is reachable from outside: every
// address it's forwarded on (one per bind).
func forwardedTo(t flk.PortTable, mc flk.Machine, p flk.MachinePort) string {
	key := fmt.Sprintf("%s/%d", p.Proto, p.Port)
	var addrs []string
	for _, x := range t.Active {
		if x.Key == key && x.Machine == mc.ID {
			addrs = append(addrs, x.Address)
		}
	}
	if len(addrs) > 0 {
		return strings.Join(addrs, ", ")
	}
	for _, x := range t.Blocked {
		if x.Key == key && x.Machine == mc.ID {
			return styleBad.Render("blocked: " + x.Blocked)
		}
	}
	for _, x := range t.Waiting {
		if x.Key == key && x.Machine == mc.ID {
			return styleWarn.Render("waiting: another machine has it")
		}
	}
	if !mc.Started() {
		return styleDim.Render("not forwarded (stopped)")
	}
	return styleDim.Render("not forwarded")
}

func (m *Model) volumeOverview(a flk.App, v flk.Volume) []string {
	attached := styleDim.Render("unattached")
	if v.AttachedMachine != "" {
		attached = v.AttachedMachine
		for _, mc := range a.Machines {
			if mc.ID == v.AttachedMachine {
				attached = or(mc.Name, mc.ID) + " (" + mc.ID + ")"
			}
		}
	}
	out := []string{
		field("name", v.Name),
		field("id", v.ID),
		field("size", fmt.Sprintf("%dGB", v.SizeGB)),
		field("path", v.Path),
	}
	if actions.External(v, m.hc.Flk.StateDir) {
		out = append(out, field("", styleDim.Render("external: outside flk's state dir")))
	}
	return append(out, field("attached", attached), field("created", when(v.CreatedAt)))
}

func (m *Model) hostOverview() []string {
	h := m.hc.Host
	health := styleOK.Render("✔ ready")
	if !h.OK {
		health = styleBad.Render("✘ not ready")
	}
	boot := styleOK.Render("installed")
	if !h.BootService {
		boot = styleWarn.Render("missing") + " (machines won't come back after a reboot)"
	}
	out := []string{
		field("flk", or(m.hc.Flk.Version, "?")),
		field("state", m.hc.Flk.StateDir),
		field("source", m.hc.Flk.Source),
		field("LAN IP", or(h.LanIP, "?")),
		field("address", or(h.Address, or(h.LanIP, "?"))+styleDim.Render(" (advertised; host.toml address)")),
		field("boot", boot),
		field("health", health),
	}
	for i, d := range m.hc.MountDirs {
		label := ""
		if i == 0 {
			label = "data dirs"
		}
		out = append(out, field(label, d))
	}
	return out
}

// portLines lists an app's ports: active, then waiting and blocked.
func portLines(t flk.PortTable, label string) []string {
	var out []string
	add := func(s string) {
		l := strings.Repeat(" ", len(label))
		if len(out) == 0 {
			l = styleLabel.Render(label)
		}
		out = append(out, l+s)
	}
	for _, p := range t.Active {
		add(fmt.Sprintf("%s → %s", p.Shown(), p.Address))
	}
	for _, p := range t.Waiting {
		add(fmt.Sprintf("%s %s (machine %s; another machine has it)", p.Shown(), styleWarn.Render("waiting"), p.Machine))
	}
	for _, p := range t.Blocked {
		add(fmt.Sprintf("%s %s: %s", p.Shown(), styleBad.Render("blocked"), p.Blocked))
	}
	if len(out) == 0 {
		add(styleDim.Render("none forwarded"))
	}
	return out
}

func field(label, value string) string {
	return styleLabel.Render(fmt.Sprintf("%-9s", label)) + " " + value
}

func stateText(mc flk.Machine) string {
	if mc.ShouldRun() {
		return styleBad.Render(mc.State + ", should be " + mc.DesiredState)
	}
	return mc.State
}

func size(cpus, memMB int) string {
	return fmt.Sprintf("%d cpus · %dMB", cpus, memMB)
}

func restartText(r flk.Restart, n *flk.Restarts) string {
	s := r.Policy
	if r.Policy != "never" && r.Policy != "no" {
		s += " · " + plural(r.Retries, "retry")
	}
	switch {
	case n == nil:
	case n.GaveUpAt != "":
		s += " · " + styleBad.Render("gave up "+when(n.GaveUpAt)) + " after " + plural(n.Count, "restart")
	case n.Count > 0:
		s += fmt.Sprintf(" · restarted %d× (last %s)", n.Count, when(n.LastAt))
	}
	return s
}

func portSuffix(p int) string {
	if p == 0 {
		return ""
	}
	return fmt.Sprintf(":%d", p)
}

func externalNote(v flk.Volume, stateDir string) string {
	if actions.External(v, stateDir) {
		return styleDim.Render(" (external)")
	}
	return ""
}

// when shows a flk timestamp in UTC, or as given if it doesn't parse.
func when(ts string) string {
	t, err := time.Parse(time.RFC3339, ts)
	if err != nil {
		return or(ts, "-")
	}
	return t.UTC().Format("2006-01-02 15:04Z")
}
