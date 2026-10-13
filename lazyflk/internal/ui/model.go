// Package ui is lazyflk's Bubble Tea interface. Every flk call runs as a
// tea.Cmd (in the background), never in Update or View.
package ui

import (
	"context"
	"fmt"
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"

	"lazyflk/internal/flk"
)

const (
	minWidth, minHeight = 80, 24
	maxAttention        = 4
)

type Options struct {
	Client   *flk.Client
	Demo     bool
	ReadOnly bool
	Refresh  time.Duration // 0: load once
}

type Model struct {
	opt           Options
	width, height int

	hc      *flk.HostContext // last good `flk context --all --json`
	apps    []flk.App        // hc.Apps, problems first
	err     error            // last load error, shown alongside stale data
	loading bool

	nodes     []node
	cursor    int // index into nodes; always a selectable node once loaded
	top       int // first tree line shown
	collapsed map[string]bool
}

type contextMsg struct {
	hc  flk.HostContext
	err error
}

type tickMsg struct{}

func New(opt Options) *Model {
	return &Model{opt: opt, collapsed: map[string]bool{}, loading: true}
}

func (m *Model) Init() tea.Cmd {
	return tea.Batch(m.load(), m.tick())
}

func (m *Model) load() tea.Cmd {
	c := m.opt.Client
	return func() tea.Msg {
		hc, err := c.HostContext(context.Background())
		return contextMsg{hc, err}
	}
}

func (m *Model) tick() tea.Cmd {
	if m.opt.Refresh <= 0 {
		return nil
	}
	return tea.Tick(m.opt.Refresh, func(time.Time) tea.Msg { return tickMsg{} })
}

func (m *Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
	case contextMsg:
		m.loading = false
		m.err = msg.err
		if msg.err == nil {
			m.setContext(msg.hc)
		}
	case tickMsg:
		if m.loading {
			return m, m.tick()
		}
		m.loading = true
		return m, tea.Batch(m.load(), m.tick())
	case tea.KeyPressMsg:
		switch msg.String() {
		case "q", "ctrl+c":
			return m, tea.Quit
		case "up", "k":
			m.move(-1)
		case "down", "j":
			m.move(1)
		case "pgup":
			m.move(-m.treeHeight())
		case "pgdown":
			m.move(m.treeHeight())
		case "left":
			m.fold(true)
		case "right":
			m.fold(false)
		}
	}
	return m, nil
}

// setContext swaps in fresh data, keeping the selection on the same item.
func (m *Model) setContext(hc flk.HostContext) {
	key := ""
	if m.hc != nil && m.cursor < len(m.nodes) {
		key = m.nodes[m.cursor].key(m.apps)
	}
	m.hc = &hc
	m.apps = sortApps(hc.Apps, hc.NextSteps)
	m.rebuild(key)
}

func (m *Model) rebuild(key string) {
	m.nodes = buildTree(m.hc, m.apps, m.collapsed)
	m.cursor = -1
	for i, n := range m.nodes {
		if !n.selectable() {
			continue
		}
		if m.cursor < 0 {
			m.cursor = i
		}
		if n.key(m.apps) == key {
			m.cursor = i
			break
		}
	}
}

func (m *Model) move(delta int) {
	if m.hc == nil {
		return
	}
	step := 1
	if delta < 0 {
		step = -1
	}
	for range max(delta*step, 1) {
		for i := m.cursor + step; i >= 0 && i < len(m.nodes); i += step {
			if m.nodes[i].selectable() {
				m.cursor = i
				break
			}
		}
	}
}

// fold collapses or expands the selected app (or the app of a selected child).
func (m *Model) fold(collapse bool) {
	if m.hc == nil {
		return
	}
	n := m.nodes[m.cursor]
	if n.kind < kindApp || n.kind > kindPorts {
		return
	}
	key := "app/" + m.apps[n.app].Name
	if m.collapsed[key] == collapse {
		return
	}
	m.collapsed[key] = collapse
	m.rebuild(key)
}

func (m *Model) View() tea.View {
	v := tea.NewView(m.Render())
	v.AltScreen = true
	v.WindowTitle = "lazyflk"
	return v
}

// layout returns the inner widths of the two panes.
func (m *Model) layout() (left, right int) {
	left = min(max((m.width-3)*37/100, 24), 40)
	return left, m.width - 3 - left
}

func (m *Model) attention() []string {
	if m.hc == nil {
		return nil
	}
	var out []string
	if m.err != nil {
		out = append(out, styleBad.Render("✘ refresh failed: ")+firstLine(m.err.Error()))
	}
	for _, s := range m.hc.NextSteps {
		out = append(out, styleWarn.Render("! ")+s)
	}
	if len(out) == 0 {
		out = append(out, styleOK.Render("✔ ")+"nothing needs attention")
	}
	if len(out) > maxAttention {
		more := len(out) - maxAttention + 1
		out = append(out[:maxAttention-1], styleDim.Render(fmt.Sprintf("… %d more: flk context --all", more)))
	}
	return out
}

func (m *Model) treeHeight() int {
	return max(m.height-5-max(len(m.attention()), 1), 1)
}

// Render draws the whole screen as plain styled text (View wraps it).
func (m *Model) Render() string {
	if m.width < minWidth || m.height < minHeight {
		return fmt.Sprintf("lazyflk needs a %dx%d terminal (this one is %dx%d)", minWidth, minHeight, m.width, m.height)
	}
	lw, rw := m.layout()
	attn := m.attention()
	if len(attn) == 0 {
		attn = []string{""}
	}
	body := m.treeHeight()
	var b strings.Builder
	line := func(s string) { b.WriteString(s + "\n") }

	line("┌" + m.topRule(m.width-2) + "┐")
	left, right := m.treeLines(lw-2, body), m.detailLines(rw-2, body)
	for i := range body {
		line("│ " + fit(left[i], lw-2) + " │ " + fit(right[i], rw-2) + " │")
	}
	line("├" + rule("Needs attention", lw) + "┴" + rule("", rw) + "┤")
	for _, s := range attn {
		line("│ " + fit(s, m.width-4) + " │")
	}
	line("├" + rule("", m.width-2) + "┤")
	line("│ " + fit(m.footer(), m.width-4) + " │")
	b.WriteString("└" + rule("", m.width-2) + "┘")
	return b.String()
}

func (m *Model) topRule(w int) string {
	title := "lazyflk ─ "
	switch {
	case m.hc != nil:
		h := m.hc.Host
		if h.OK {
			title += "host ready"
		} else {
			title += "host NOT ready (" + plural(len(h.Problems), "problem") + ")"
		}
		if h.LanIP != "" {
			title += " · LAN " + h.LanIP
		}
		if h.BootService {
			title += " · boot service ok"
		} else {
			title += " · boot service missing"
		}
	case m.err != nil:
		title += "flk error"
	default:
		title += "loading…"
	}
	var status []string
	if m.loading && m.hc != nil {
		status = append(status, "refreshing…")
	}
	if m.opt.ReadOnly {
		status = append(status, "read-only")
	}
	if m.opt.Demo {
		status = append(status, "demo")
	}
	right := ""
	if len(status) > 0 {
		right = " " + strings.Join(status, " · ") + " "
	}
	return rule(title, w-len([]rune(right))) + right
}

func (m *Model) footer() string {
	keys := []string{"↑↓", "move", "←→", "fold", "q", "quit"}
	var parts []string
	for i := 0; i < len(keys); i += 2 {
		parts = append(parts, styleKey.Render(keys[i])+" "+keys[i+1])
	}
	return strings.Join(parts, "  ")
}

// treeLines renders exactly h lines of tree, scrolled to keep the cursor in view.
func (m *Model) treeLines(w, h int) []string {
	out := make([]string, h)
	if m.hc == nil {
		return out
	}
	if m.cursor < m.top {
		m.top = m.cursor
	}
	if m.cursor >= m.top+h {
		m.top = m.cursor - h + 1
	}
	m.top = max(min(m.top, len(m.nodes)-h), 0)
	for i := range h {
		j := m.top + i
		if j >= len(m.nodes) {
			break
		}
		s := m.treeLine(m.nodes[j])
		if j == m.cursor {
			s = styleSelected.Render(fit(s, w))
		}
		out[i] = s
	}
	return out
}

// detailLines renders exactly h lines of the right pane.
func (m *Model) detailLines(w, h int) []string {
	out := make([]string, h)
	var title string
	var body []string
	switch {
	case m.hc != nil:
		title, body = m.detail(m.nodes[m.cursor])
		title = styleTitle.Render(title) + " ─ " + styleSelected.Render(" Overview ")
	case m.err != nil:
		title = styleBad.Render("flk failed")
		body = append([]string{"$ " + flk.CommandLine("context", "--all", "--json"), ""}, wrap(m.err.Error(), w)...)
	default:
		title = "loading…"
		body = []string{"$ " + flk.CommandLine("context", "--all", "--json")}
	}
	out[0] = title
	if h > 1 {
		copy(out[2:], body)
	}
	return out
}

func plural(n int, word string) string {
	if n == 1 {
		return "1 " + word
	}
	if strings.HasSuffix(word, "y") {
		return fmt.Sprintf("%d %sies", n, strings.TrimSuffix(word, "y"))
	}
	return fmt.Sprintf("%d %ss", n, word)
}

func firstLine(s string) string {
	s, _, _ = strings.Cut(strings.TrimSpace(s), "\n")
	return s
}

// wrap breaks plain text into lines of at most w cells, keeping its newlines.
func wrap(s string, w int) []string {
	var out []string
	for _, para := range strings.Split(strings.TrimRight(s, "\n"), "\n") {
		line := ""
		for _, word := range strings.Fields(para) {
			if line != "" && len([]rune(line))+1+len([]rune(word)) > w {
				out = append(out, line)
				line = ""
			}
			if line != "" {
				line += " "
			}
			line += word
		}
		out = append(out, line)
	}
	return out
}
