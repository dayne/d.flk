package ui

import (
	"context"
	"sort"
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"

	"lazyflk/internal/actions"
	"lazyflk/internal/flk"
)

// paletteView is the command palette (SPEC 5.5): every flk command, from
// `flk help --all --json`, found by typing part of its name.
type paletteView struct {
	query  string
	cursor int
}

// helpSource is flk's command table; it changes only when flk does.
func (m *Model) helpSource() *source {
	c := m.opt.Client
	return flkSource([]string{"help", "--all", "--json"}, time.Hour,
		func(ctx context.Context) (flk.Help, error) { return c.Help(ctx) })
}

func (m *Model) flkHelp() (flk.Help, bool) {
	if f := m.cache[m.helpSource().cmd]; f != nil {
		h, ok := f.val.(flk.Help)
		return h, ok
	}
	return flk.Help{}, false
}

func (m *Model) openPalette() tea.Cmd {
	m.palette = &paletteView{}
	return m.want(m.helpSource())
}

// selectedApp is the app of the selection, if any.
func (m *Model) selectedApp() string {
	if n, ok := m.selected(); ok && n.kind >= kindApp && n.kind <= kindPorts {
		return m.apps[n.app].Name
	}
	return ""
}

// paletteMatches ranks commands by how well their name, then their
// summary, matches the query: a prefix beats a word start beats a
// substring beats letters in order.
func (m *Model) paletteMatches() []actions.Entry {
	h, ok := m.flkHelp()
	if !ok {
		return nil
	}
	all := actions.Palette(h, m.selectedApp(), m.opt.ReadOnly)
	q := strings.ToLower(strings.TrimSpace(m.palette.query))
	if q == "" {
		return all
	}
	type scored struct {
		e     actions.Entry
		score int
	}
	var out []scored
	for _, e := range all {
		if s := matchScore(strings.ToLower(e.Name), strings.ToLower(e.Summary), q); s > 0 {
			out = append(out, scored{e, s})
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].score > out[j].score })
	res := make([]actions.Entry, len(out))
	for i, s := range out {
		res[i] = s.e
	}
	return res
}

func matchScore(name, summary, q string) int {
	switch {
	case strings.HasPrefix(name, q):
		return 5
	case strings.Contains(" "+name, " "+q):
		return 4
	case strings.Contains(name, q):
		return 3
	case strings.Contains(summary, q):
		return 2
	case subsequence(name, q):
		return 1
	}
	return 0
}

func subsequence(s, q string) bool {
	i := 0
	for _, r := range s {
		if i < len(q) && byte(r) == q[i] {
			i++
		}
	}
	return i == len(q)
}

func (m *Model) paletteKey(msg tea.KeyPressMsg) tea.Cmd {
	p := m.palette
	list := m.paletteMatches()
	switch k := msg.String(); k {
	case "esc":
		m.palette = nil
	case "up", "ctrl+p":
		p.cursor = max(p.cursor-1, 0)
	case "down", "ctrl+n", "tab":
		p.cursor = min(p.cursor+1, max(len(list)-1, 0))
	case "enter":
		if len(list) == 0 {
			return nil
		}
		e := list[min(p.cursor, len(list)-1)]
		if e.Action.Disabled != "" {
			m.note = e.Name + " doesn't run from lazyflk (why: below)"
			return nil
		}
		m.palette = nil
		return m.choose(or(m.selectedApp(), "host"), e.Action)
	case "backspace":
		if r := []rune(p.query); len(r) > 0 {
			p.query = string(r[:len(r)-1])
		}
		p.cursor = 0
	case "ctrl+u":
		p.query, p.cursor = "", 0
	case "space":
		p.query += " "
		p.cursor = 0
	default:
		if msg.Text != "" {
			p.query += msg.Text
			p.cursor = 0
		}
	}
	return nil
}

func (m *Model) paletteBox() []string {
	p := m.palette
	w := min(m.width-4, 100)
	inner := w - 4
	h := m.height - 4
	body := []string{styleKey.Render(": ") + p.query + "▏"}
	list := m.paletteMatches()
	if _, ok := m.flkHelp(); !ok {
		body = append(body, "", styleDim.Render("loading flk's command table (flk help --all --json)…"))
		if f := m.cache[m.helpSource().cmd]; f != nil && f.err != nil {
			body = append(body, wrap(f.err.Error(), inner)...)
		}
	}
	room := h - 2 - len(body) - 4 // list rows: leave room for the usage
	p.cursor = min(p.cursor, max(len(list)-1, 0))
	first := max(min(p.cursor-room/2, len(list)-room), 0)
	nameW := 0
	for _, e := range list {
		nameW = max(nameW, ansi.StringWidth(e.Name))
	}
	nameW = min(nameW, inner/3)
	for i := first; i < len(list) && i < first+room; i++ {
		e := list[i]
		line := fit(e.Name, nameW) + "  " + styleDim.Render(e.Summary)
		if e.Action.Disabled != "" {
			line = styleDim.Render(fit(e.Name, nameW) + "  " + e.Summary)
		}
		if i == p.cursor {
			line = styleSelected.Render(fit(ansi.Strip(line), inner))
		}
		body = append(body, line)
	}
	if len(list) == 0 && p.query != "" {
		body = append(body, styleDim.Render("no command matches: flk help --all lists them all"))
	}
	for len(body) < h-8 {
		body = append(body, "")
	}
	if len(list) > 0 {
		e := list[p.cursor]
		body = append(body, "")
		body = append(body, wrapIndent(e.Usage, inner)...)
		if e.Action.Disabled != "" {
			for _, l := range wrap("not here: "+e.Action.Disabled, inner) {
				body = append(body, styleWarn.Render(l))
			}
		}
	}
	foot := keyHints("type", "to find", "↑↓", "choose", "enter", "fill in and run", "esc", "close")
	if m.note != "" {
		foot = styleWarn.Render(m.note)
	}
	return box("flk commands ─ from flk help --all --json", body[:min(len(body), h-4)], foot, w)
}

func wrapIndent(s string, w int) []string {
	out := wrap(s, w)
	for i := 1; i < len(out); i++ {
		out[i] = "  " + out[i]
	}
	return out
}
