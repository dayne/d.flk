package ui

import (
	"context"
	"path/filepath"
	"time"

	tea "charm.land/bubbletea/v2"

	"lazyflk/internal/actions"
	"lazyflk/internal/flk"
	"lazyflk/internal/providers"
)

// Providers (SPEC 10): sections below Host for the rest of what the
// admin looks after. Each loads in the background like a tab's source.

func (m *Model) providerSource(p providers.Provider) *source {
	host, env := m.opt.Host, m.providerEnv()
	return &source{cmd: p.Command(), ttl: 10 * time.Second,
		load: func(ctx context.Context) (any, error) {
			ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
			defer cancel()
			return p.Load(ctx, host, env)
		}}
}

func (m *Model) providerEnv() providers.Env {
	env := providers.Env{StateDir: m.hc.Flk.StateDir, MountDirs: m.hc.MountDirs}
	if f := m.cache[m.diskUseSource().cmd]; f != nil {
		if du, ok := f.val.(flk.DiskUse); ok && du.Backups != nil {
			env.BackupDir = du.Backups.Dir
		}
	}
	return env
}

// providerData is a provider's items as last loaded, and its error.
func (m *Model) providerData(i int) ([]providers.Item, error, bool) {
	f := m.cache[m.opt.Providers[i].Command()]
	if f == nil {
		return nil, nil, false
	}
	items, _ := f.val.([]providers.Item)
	return items, f.err, f.val != nil || f.err != nil
}

func (m *Model) providerItem(n node) providers.Item {
	items, _, _ := m.providerData(n.prov)
	if n.item < len(items) {
		return items[n.item]
	}
	return providers.Item{}
}

// wantProviders keeps every provider's section fresh; the backup dir
// comes from flk disk, so that loads too.
func (m *Model) wantProviders() tea.Cmd {
	if m.opt.Host == nil || len(m.opt.Providers) == 0 || m.hc == nil {
		return nil
	}
	cmds := []tea.Cmd{}
	if m.hc.Schema >= 1 {
		cmds = append(cmds, m.want(m.diskUseSource()))
	}
	for _, p := range m.opt.Providers {
		cmds = append(cmds, m.want(m.providerSource(p)))
	}
	return tea.Batch(cmds...)
}

// isProviderKey reports whether a fetched result is a provider's, which
// changes the tree.
func (m *Model) isProviderKey(key string) bool {
	for _, p := range m.opt.Providers {
		if p.Command() == key {
			return true
		}
	}
	return false
}

func (m *Model) providerNodes() []node {
	var out []node
	for i, p := range m.opt.Providers {
		items, err, loaded := m.providerData(i)
		out = append(out, node{kind: kindInfo}, node{kind: kindHeading, text: p.Name()})
		switch {
		case !loaded:
			out = append(out, node{kind: kindInfo, text: "loading…"})
		case err != nil && len(items) == 0:
			out = append(out, node{kind: kindInfo, text: "can't list: " + firstLine(err.Error())})
		case len(items) == 0:
			out = append(out, node{kind: kindInfo, text: "nothing here"})
		}
		for j, it := range items {
			out = append(out, node{kind: kindProvider, prov: i, item: j, pkey: it.Key})
		}
	}
	return out
}

func (m *Model) providerLine(n node) string {
	it := m.providerItem(n)
	s := "  " + it.Label
	switch it.State {
	case providers.Bad:
		return styleBad.Render(s)
	case providers.Warn:
		return styleWarn.Render(s)
	case providers.Off:
		return styleDim.Render(s)
	}
	return s
}

func (m *Model) providerDetail(n node, w int) (string, []string) {
	it := m.providerItem(n)
	p := m.opt.Providers[n.prov]
	var out []string
	for _, l := range wrapIndent("$ "+p.Command(), w) {
		out = append(out, styleDim.Render(l))
	}
	if _, err, _ := m.providerData(n.prov); err != nil {
		out = append(out, "", styleBad.Render(firstLine(err.Error())), styleDim.Render("(showing the last good result)"))
	}
	out = append(out, "")
	out = append(out, it.Lines...)
	for _, pr := range it.Problems {
		out = append(out, "", styleBad.Render("! ")+pr)
	}
	return it.Title, out
}

// providerAttention is each provider's problems, with the item's fix.
func (m *Model) providerAttention() []attnItem {
	var out []attnItem
	for i := range m.opt.Providers {
		items, _, _ := m.providerData(i)
		for _, it := range items {
			for _, p := range it.Problems {
				a := attnItem{icon: styleWarn.Render("!"), text: p}
				if it.Fix != nil && !m.opt.ReadOnly {
					f := *it.Fix
					a.fix = &f
				}
				out = append(out, a)
			}
		}
	}
	return out
}

// runnerFor is the client for an action's program: flk, or a host tool.
func (m *Model) runnerFor(prog string) *flk.Client {
	if prog == "" || m.opt.Host == nil {
		return m.opt.Client
	}
	return flk.New(m.opt.Host(prog))
}

// openCommandLogs follows a provider item's logs.
func (m *Model) openCommandLogs(c actions.Command, title string) tea.Cmd {
	m.logs = newCommandLogs(m.runnerFor(c.Program), c.Program, c.Args, title)
	return m.logs.start()
}

// appActionsSource reads the app's .lazyflk.toml (next to its flk.toml).
func (m *Model) appActionsSource(a flk.App) *source {
	path := providers.LazyflkFile(a.ConfigPath)
	return &source{cmd: "read " + path, ttl: 10 * time.Second,
		load: func(context.Context) (any, error) {
			list, err := providers.LoadAppActions(a.ConfigPath)
			return list, err
		}}
}

// appActions are the app's own actions for the menu of the app or one of
// its machines.
func (m *Model) appActions(n node) []actions.Action {
	if n.kind != kindApp && n.kind != kindMachine {
		return nil
	}
	a := m.apps[n.app]
	if a.ConfigPath == "" {
		return nil
	}
	f := m.cache[m.appActionsSource(a).cmd]
	if f == nil {
		return nil
	}
	list, _ := f.val.([]providers.AppAction)
	var mc *flk.Machine
	if n.kind == kindMachine {
		mc = &a.Machines[n.machine]
	}
	acts := providers.AppActionItems(list, a, mc, filepath.Dir(a.ConfigPath))
	if f.err != nil {
		acts = append(acts, actions.Action{Key: "", Label: ".lazyflk.toml", Disabled: firstLine(f.err.Error())})
	}
	return acts
}
