package ui

import (
	"fmt"
	"lazyflk/internal/actions"
	"sort"
	"strings"

	"lazyflk/internal/flk"
)

type nodeKind int

const (
	kindHeading nodeKind = iota // "Apps", "Host": not selectable
	kindInfo                    // a hint line: not selectable
	kindApp
	kindMachine
	kindVolume
	kindPorts
	kindHost
	kindProvider // an item of a provider's section (Storage, Podman, Services)
)

// node is one line of the left tree. app, machine and volume index into
// the model's sorted apps.
type node struct {
	kind    nodeKind
	text    string
	app     int
	machine int
	volume  int
	prov    int // kindProvider: the provider, and its item
	item    int
	pkey    string // kindProvider: the item's stable key
}

func (n node) selectable() bool { return n.kind >= kindApp }

// key identifies a node across refreshes so the selection stays put.
func (n node) key(apps []flk.App) string {
	switch n.kind {
	case kindApp:
		return "app/" + apps[n.app].Name
	case kindMachine:
		return "machine/" + apps[n.app].Name + "/" + apps[n.app].Machines[n.machine].ID
	case kindVolume:
		return "volume/" + apps[n.app].Name + "/" + apps[n.app].Volumes[n.volume].ID
	case kindPorts:
		return "ports/" + apps[n.app].Name
	case kindHost:
		return "host"
	case kindProvider:
		return "prov/" + n.pkey
	}
	return ""
}

// appProblems lists what's wrong with an app, from its own state and the
// next_steps flk reports for it ("APP: ...").
func appProblems(a flk.App, steps []string) []string {
	var out []string
	for _, m := range a.Machines {
		if m.ShouldRun() {
			out = append(out, fmt.Sprintf("machine %s should be running but is %s", m.ID, m.State))
		}
	}
	for _, p := range a.Ports.Blocked {
		out = append(out, fmt.Sprintf("port %s blocked: %s", p.Shown(), p.Blocked))
	}
	for _, s := range steps {
		if rest, ok := strings.CutPrefix(s, a.Name+": "); ok {
			out = append(out, rest)
		}
	}
	return out
}

// sortApps orders apps with problems first, then by name.
func sortApps(apps []flk.App, steps []string) []flk.App {
	out := append([]flk.App(nil), apps...)
	sort.SliceStable(out, func(i, j int) bool {
		pi, pj := len(appProblems(out[i], steps)) > 0, len(appProblems(out[j], steps)) > 0
		if pi != pj {
			return pi
		}
		return out[i].Name < out[j].Name
	})
	return out
}

// portKeys is an app's ports for its tree line, grouped by the address
// they're bound to: "tcp/25565 udp/19132", or "10.47.11.3: tcp/25565
// udp/19132". Waiting ones end in ?, blocked ones in !.
func portKeys(t flk.PortTable, binds bool) []string {
	var order []string
	byBind := map[string][]string{}
	add := func(p flk.Port, mark string) {
		b := ""
		if p.Bind != nil {
			b = *p.Bind
		}
		if _, ok := byBind[b]; !ok {
			order = append(order, b)
		}
		byBind[b] = append(byBind[b], p.Key+mark)
	}
	for _, p := range t.Active {
		add(p, "")
	}
	for _, p := range t.Waiting {
		add(p, "?")
	}
	for _, p := range t.Blocked {
		add(p, "!")
	}
	var out []string
	for _, b := range order {
		keys := byBind[b]
		if b != "" && binds {
			keys[0] = b + ": " + keys[0]
		}
		out = append(out, keys...)
	}
	return out
}

func startedCount(a flk.App) int {
	n := 0
	for _, m := range a.Machines {
		if m.Started() {
			n++
		}
	}
	return n
}

// buildTree lays out apps (expanded unless collapsed) and the host.
func buildTree(hc *flk.HostContext, apps []flk.App, collapsed map[string]bool, extra ...node) []node {
	nodes := []node{{kind: kindHeading, text: "Apps"}}
	if len(apps) == 0 {
		nodes = append(nodes, node{kind: kindInfo, text: "no apps: flk help first-app"})
	}
	for i, a := range apps {
		nodes = append(nodes, node{kind: kindApp, app: i})
		if collapsed["app/"+a.Name] {
			continue
		}
		for j := range a.Machines {
			nodes = append(nodes, node{kind: kindMachine, app: i, machine: j})
		}
		for j := range a.Volumes {
			nodes = append(nodes, node{kind: kindVolume, app: i, volume: j})
		}
		if len(portKeys(a.Ports, true)) > 0 {
			nodes = append(nodes, node{kind: kindPorts, app: i})
		}
	}
	nodes = append(nodes, node{kind: kindInfo}, node{kind: kindHeading, text: "Host"}, node{kind: kindHost})
	return append(nodes, extra...)
}

// treeLine renders one node, without the selection highlight.
func (m *Model) treeLine(n node) string {
	switch n.kind {
	case kindHeading:
		return styleTitle.Render(n.text)
	case kindInfo:
		return styleDim.Render("  " + n.text)
	case kindProvider:
		return m.providerLine(n)
	case kindHost:
		if m.hc.Host.OK {
			return "  health " + styleOK.Render("✔")
		}
		return "  health " + styleBad.Render(fmt.Sprintf("✘ %d", len(m.hc.Host.Problems)))
	}
	a := m.apps[n.app]
	switch n.kind {
	case kindApp:
		arrow := "▾"
		if m.collapsed["app/"+a.Name] {
			arrow = "▸"
		}
		started := startedCount(a)
		icon := styleOK.Render("●")
		if started < len(a.Machines) || len(a.Machines) == 0 {
			icon = styleDim.Render("○")
		}
		s := fmt.Sprintf("%s %s  %d/%d %s", arrow, a.Name, started, len(a.Machines), icon)
		if len(appProblems(a, m.hc.NextSteps)) > 0 {
			s += " " + styleBad.Render("!")
		}
		return s
	case kindMachine:
		mc := a.Machines[n.machine]
		return "  " + machineIcon(mc) + " " + or(mc.Name, mc.ID)
	case kindVolume:
		v := a.Volumes[n.volume]
		s := fmt.Sprintf("  ▢ %s %dGB", v.Name, v.SizeGB)
		if actions.External(v, m.hc.Flk.StateDir) {
			s += styleDim.Render(" (external)")
		}
		return s
	case kindPorts:
		return "  ⇄ " + strings.Join(portKeys(a.Ports, true), " ")
	}
	return ""
}

func machineIcon(mc flk.Machine) string {
	switch {
	case mc.ShouldRun():
		return styleBad.Render("!")
	case mc.Started():
		return styleOK.Render("●")
	}
	return styleDim.Render("○")
}

func or(s, fallback string) string {
	if s == "" {
		return fallback
	}
	return s
}
