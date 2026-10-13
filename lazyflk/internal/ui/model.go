// Package ui is lazyflk's Bubble Tea interface. Every flk call runs as a
// tea.Cmd (in the background), never in Update or View.
package ui

import (
	"context"
	"fmt"
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"

	"lazyflk/internal/actions"
	"lazyflk/internal/flk"
	"lazyflk/internal/host"
)

const minWidth, minHeight = 80, 24

type Options struct {
	Client   *flk.Client
	Disk     func(ctx context.Context, paths []string) ([]host.Disk, error) // nil: no disk usage
	Demo     bool
	ReadOnly bool
	Refresh  time.Duration // 0: load once
}

type Model struct {
	opt           Options
	width, height int
	now           func() time.Time

	hc      *flk.HostContext // last good `flk context --all --json`
	apps    []flk.App        // hc.Apps, problems first
	err     error            // last load error, shown alongside stale data
	loading bool

	nodes     []node
	cursor    int // index into nodes; always a selectable node once loaded
	top       int // first tree line shown
	collapsed map[string]bool

	tabs      map[nodeKind]int // selected tab per kind of selection
	detailTop int              // detail pane scroll
	cache     map[string]*fetched

	logs *logsView // full-screen logs, when open
	help bool      // help screen, when open

	// actions (M2): at most one of menu, form, confirm is open
	menu    *menuView
	form    *formView
	confirm *confirmView
	jobs    []*job // the command log, oldest first
	jobSeq  int
	shown   *job // the job modal, when open
	cmdlog  *cmdlogView
	note    string // a one-off message in the footer, cleared by the next key

	attn       bool // the Needs attention panel has focus
	attnCursor int

	loadGen   int  // the newest context load; older answers are dropped
	quitting  bool // quit once the running job ends
	quitArmed bool // q pressed once while a job runs
}

type contextMsg struct {
	gen int
	hc  flk.HostContext
	err error
}

type tickMsg struct{}

func New(opt Options) *Model {
	return &Model{opt: opt, now: time.Now, collapsed: map[string]bool{}, loading: true,
		tabs: map[nodeKind]int{}, cache: map[string]*fetched{}}
}

func (m *Model) Init() tea.Cmd {
	return tea.Batch(m.load(), m.tick())
}

func (m *Model) load() tea.Cmd {
	m.loadGen++
	m.loading = true
	c, gen := m.opt.Client, m.loadGen
	return func() tea.Msg {
		hc, err := c.HostContext(context.Background())
		return contextMsg{gen, hc, err}
	}
}

// reload refreshes the main view now, e.g. after an action, even if a
// load is under way (its older answer is then dropped).
func (m *Model) reload() tea.Cmd { return m.load() }

func (m *Model) tick() tea.Cmd {
	if m.opt.Refresh <= 0 {
		return nil
	}
	return tea.Tick(m.opt.Refresh, func(time.Time) tea.Msg { return tickMsg{} })
}

func (m *Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	before := m.viewKey()
	cmd := m.update(msg)
	if m.viewKey() != before {
		m.detailTop = 0
	}
	return m, tea.Batch(cmd, m.sync())
}

// sync starts loading whatever the screen shows that is missing or stale.
func (m *Model) sync() tea.Cmd {
	if m.hc == nil {
		return nil
	}
	n := m.nodes[m.cursor]
	return tea.Batch(m.want(m.tabSource(n, m.tabName(n))), m.want(m.diskSource()))
}

func (m *Model) update(msg tea.Msg) tea.Cmd {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
	case contextMsg:
		if msg.gen != m.loadGen {
			return nil
		}
		m.loading = false
		m.err = msg.err
		if msg.err == nil {
			m.setContext(msg.hc)
		}
	case tickMsg:
		if m.loading {
			return m.tick()
		}
		return tea.Batch(m.load(), m.tick())
	case fetchedMsg:
		m.gotFetched(msg)
	case logStartMsg:
		if msg.v == m.logs {
			return m.logs.handleStart(msg)
		}
		if msg.stream != nil {
			msg.stream.Stop()
		}
	case logChunkMsg:
		if msg.v == m.logs {
			return m.logs.handleChunk(msg)
		}
	case jobStartMsg:
		return m.jobStarted(msg)
	case jobChunkMsg:
		return m.jobChunk(msg)
	case tea.PasteMsg:
		m.paste(msg.Content)
	case tea.KeyPressMsg:
		return m.key(msg)
	}
	return nil
}

func (m *Model) key(msg tea.KeyPressMsg) tea.Cmd {
	k := msg.String()
	m.note = ""
	if k != "q" && k != "ctrl+c" {
		m.quitArmed = false
	}
	typing := m.form != nil || m.confirm != nil || (m.logs != nil && m.logs.editing)
	switch {
	case k == "ctrl+c" && m.shown != nil && m.shown.running():
		m.shown.interrupt()
		return nil
	case k == "ctrl+c":
		return m.quit()
	case m.help:
		m.help = false
		return nil
	case k == "?" && !typing:
		m.help = true
		return nil
	case m.confirm != nil:
		return m.confirmKey(msg)
	case m.form != nil:
		return m.formKey(msg)
	case m.menu != nil:
		return m.menuKey(msg)
	case m.shown != nil:
		return m.jobKey(k)
	case m.cmdlog != nil:
		return m.cmdlogKey(k)
	case m.logs != nil:
		cmd, open := m.logs.key(msg, m.width-4, m.height-5)
		if !open {
			m.logs = nil
		}
		return cmd
	case m.attn:
		return m.attnKey(k)
	}
	switch k {
	case "q":
		return m.quit()
	case "L":
		m.cmdlog = &cmdlogView{}
	case "enter", "x":
		return m.openMenu()
	case "a":
		if len(m.attnItems()) > 0 && m.hc != nil {
			m.attn, m.attnCursor = true, 0
		}
	case "s", "d":
		return m.shortcut(k)
	case "up", "k":
		m.move(-1)
	case "down", "j":
		m.move(1)
	case "left":
		m.fold(true)
	case "right":
		m.fold(false)
	case "tab", "shift+tab":
		m.nextTab(map[string]int{"tab": 1, "shift+tab": -1}[k])
	case "1", "2", "3", "4", "5", "6", "7", "8", "9":
		m.setTab(int(k[0] - '1'))
	case "pgdown", "ctrl+d":
		m.detailTop += max(m.treeHeight()-4, 1)
	case "pgup", "ctrl+u":
		m.detailTop = max(m.detailTop-max(m.treeHeight()-4, 1), 0)
	case "l":
		return m.openLogs()
	}
	return nil
}

// quit leaves, unless a job is running: then the first q warns, and the
// second interrupts it and quits once it has ended.
func (m *Model) quit() tea.Cmd {
	j := m.runningJob()
	if j == nil {
		if m.logs != nil {
			m.logs.stop()
		}
		return tea.Quit
	}
	if !m.quitArmed {
		m.quitArmed = true
		m.note = j.line + " is still running: press q again to interrupt it and quit"
		return nil
	}
	m.quitting = true
	if m.logs != nil {
		m.logs.stop()
	}
	j.interrupt()
	m.shown = j
	return nil
}

// shortcut runs a main-view action key: s starts or stops the selected
// machine, d deploys the selected app (or the app of a selected child).
func (m *Model) shortcut(k string) tea.Cmd {
	if m.opt.ReadOnly {
		m.note = "read-only: actions are off (started with --read-only)"
		return nil
	}
	n, ok := m.selected()
	if !ok {
		return nil
	}
	label := ""
	switch {
	case k == "s" && n.kind == kindMachine:
		label = "start"
		if mc := m.apps[n.app].Machines[n.machine]; mc.Started() {
			label = "stop"
		}
	case k == "d" && n.kind >= kindApp && n.kind <= kindPorts:
		n = node{kind: kindApp, app: n.app}
		label = "deploy"
	default:
		return nil
	}
	t, title, _ := m.target(n)
	for _, a := range actions.For(t) {
		if a.Label == label {
			return m.choose(title, a)
		}
	}
	return nil
}

// openLogs follows the logs of the selected machine, or of every machine
// of the selected app.
func (m *Model) openLogs() tea.Cmd {
	if m.hc == nil {
		return nil
	}
	n := m.nodes[m.cursor]
	if n.kind < kindApp || n.kind > kindPorts {
		return nil
	}
	a := m.apps[n.app]
	sel := -1
	if n.kind == kindMachine {
		sel = n.machine
	}
	m.logs = newLogsView(m.opt.Client, a.Name, a.Machines, sel)
	return m.logs.start()
}

func (m *Model) viewKey() string {
	if m.hc == nil {
		return ""
	}
	n := m.nodes[m.cursor]
	return n.key(m.apps) + "#" + m.tabName(n)
}

func (m *Model) tabName(n node) string {
	names := tabNames(n.kind)
	return names[min(m.tabs[n.kind], len(names)-1)]
}

func (m *Model) nextTab(step int) {
	if m.hc == nil {
		return
	}
	k := m.nodes[m.cursor].kind
	n := len(tabNames(k))
	m.tabs[k] = (m.tabs[k] + step + n) % n
}

func (m *Model) setTab(i int) {
	if m.hc == nil {
		return
	}
	k := m.nodes[m.cursor].kind
	if i < len(tabNames(k)) {
		m.tabs[k] = i
	}
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
	for i := m.cursor + delta; i >= 0 && i < len(m.nodes); i += delta {
		if m.nodes[i].selectable() {
			m.cursor = i
			return
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

// attnItem is one entry of Needs attention, with its fix when flk names one.
type attnItem struct {
	icon, text string
	fix        *actions.Action
}

func (m *Model) attnItems() []attnItem {
	if m.hc == nil {
		return nil
	}
	var items []attnItem
	if m.err != nil {
		items = append(items, attnItem{icon: styleBad.Render("✘"), text: "refresh failed: " + firstLine(m.err.Error())})
	}
	for _, s := range m.hc.NextSteps {
		it := attnItem{icon: styleWarn.Render("!"), text: s}
		if fix, ok := actions.Fix(s, m.apps); ok && !m.opt.ReadOnly {
			it.fix = &fix
		}
		items = append(items, it)
	}
	for _, s := range m.diskWarnings() {
		items = append(items, attnItem{icon: styleWarn.Render("!"), text: s})
	}
	return items
}

// attention is the Needs attention panel: one entry per problem, wrapped,
// capped at a few rows with a pointer to the rest. With focus it grows,
// starts at the selected entry and shows that entry's fix.
func (m *Model) attention() []string {
	if m.hc == nil {
		return nil
	}
	items := m.attnItems()
	if len(items) == 0 {
		return []string{styleOK.Render("✔") + " nothing needs attention"}
	}
	m.attnCursor = min(m.attnCursor, len(items)-1)
	limit, first := max(4, m.height/6), 0
	if m.attn {
		limit, first = max(6, m.height/4), m.attnCursor
	}
	var out []string
	if first > 0 {
		out = append(out, styleDim.Render(fmt.Sprintf("… %d above", first)))
	}
	for i := first; i < len(items); i++ {
		it := items[i]
		lines := wrap(it.text, m.width-6)
		var hint string
		if m.attn && i == m.attnCursor {
			hint = "no fix lazyflk can run: see the step"
			if it.fix != nil {
				hint = "enter: " + it.fix.Label
				if it.fix.Disabled != "" {
					hint = it.fix.Label + " (" + it.fix.Disabled + ")"
				}
			}
			hint = styleKey.Render(ansi.Truncate("→ "+hint, m.width-6, "…"))
		}
		left := len(items) - i
		room := limit - len(out)
		if left > 1 {
			room-- // keep a row for "… more"
		}
		if hint != "" {
			room--
		}
		if len(lines) > room {
			if room > 0 && (left == 1 || hint != "") {
				lines = append(lines[:room-1], ansi.Truncate(lines[room-1], m.width-7, "")+"…")
			} else {
				more := fmt.Sprintf("… %d more: flk context --all", left)
				if !m.attn {
					more += " (a: go through them)"
				}
				out = append(out, styleDim.Render(more))
				break
			}
		}
		for j, l := range lines {
			switch {
			case j == 0 && hint != "":
				out = append(out, styleSelected.Render("›")+" "+l)
			case j == 0:
				out = append(out, it.icon+" "+l)
			default:
				out = append(out, "  "+l)
			}
		}
		if hint != "" {
			out = append(out, "  "+hint)
		}
	}
	return out
}

func (m *Model) attnKey(k string) tea.Cmd {
	items := m.attnItems()
	if len(items) == 0 {
		m.attn = false
		return nil
	}
	switch k {
	case "esc", "a", "q":
		m.attn = false
	case "up", "k":
		m.attnCursor = max(m.attnCursor-1, 0)
	case "down", "j":
		m.attnCursor = min(m.attnCursor+1, len(items)-1)
	case "enter", "f":
		it := items[min(m.attnCursor, len(items)-1)]
		if it.fix == nil {
			m.note = "no fix lazyflk can run for this one"
			return nil
		}
		m.attn = false
		return m.choose("needs attention", *it.fix)
	}
	return nil
}

func (m *Model) treeHeight() int {
	return max(m.height-5-max(len(m.attention()), 1), 1)
}

// Render draws the whole screen as plain styled text (View wraps it).
func (m *Model) Render() string {
	if m.width < minWidth || m.height < minHeight {
		return fmt.Sprintf("lazyflk needs a %dx%d terminal (this one is %dx%d)", minWidth, minHeight, m.width, m.height)
	}
	if m.help {
		return m.helpScreen()
	}
	var base string
	switch {
	case m.shown != nil:
		base = m.jobScreen(m.shown)
	case m.cmdlog != nil:
		base = m.cmdlogScreen()
	case m.logs != nil:
		base = m.logs.render(m.width, m.height)
	default:
		base = m.mainScreen()
	}
	var top []string
	switch {
	case m.confirm != nil:
		top = m.confirmBox()
	case m.form != nil:
		top = m.formBox()
	case m.menu != nil:
		top = m.menuBox()
	}
	return overlay(base, top, m.width, m.height)
}

func (m *Model) mainScreen() string {
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
	if j := m.runningJob(); j != nil {
		status = append(status, "⟳ "+strings.Join(j.args, " "))
	}
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
	return rule(title, w-ansi.StringWidth(right)) + right
}

func keyHints(pairs ...string) string {
	var parts []string
	for i := 0; i+1 < len(pairs); i += 2 {
		parts = append(parts, styleKey.Render(pairs[i])+" "+pairs[i+1])
	}
	return strings.Join(parts, "  ")
}

func (m *Model) footer() string {
	switch {
	case m.note != "":
		return styleWarn.Render(m.note)
	case m.attn:
		return keyHints("↑↓", "move", "enter", "fix", "esc", "back")
	}
	keys := []string{"↑↓", "move", "tab", "tabs"}
	if !m.opt.ReadOnly {
		keys = append(keys, "enter", "actions")
		if n, ok := m.selected(); ok {
			switch {
			case n.kind == kindMachine && m.apps[n.app].Machines[n.machine].Started():
				keys = append(keys, "s", "stop")
			case n.kind == kindMachine:
				keys = append(keys, "s", "start")
			case n.kind == kindApp:
				keys = append(keys, "d", "deploy")
			}
		}
	}
	keys = append(keys, "l", "logs")
	if len(m.attnItems()) > 0 && m.hc != nil {
		keys = append(keys, "a", "attention")
	}
	if len(m.jobs) > 0 {
		keys = append(keys, "L", "cmd log")
	}
	return keyHints(append(keys, "?", "help", "q", "quit", "←→", "fold", "pgup/dn", "scroll")...)
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

// tabBar renders the tabs, windowed around the active one if they don't fit.
func tabBar(names []string, active, w int) string {
	parts := make([]string, len(names))
	for i, n := range names {
		parts[i] = " " + n + " "
		if i == active {
			parts[i] = styleSelected.Render(parts[i])
		}
	}
	width := func(lo, hi int) int {
		n := ansi.StringWidth(strings.Join(parts[lo:hi], ""))
		if lo > 0 {
			n++
		}
		if hi < len(parts) {
			n++
		}
		return n
	}
	lo, hi := active, active+1
	for grew := true; grew; {
		grew = false
		if hi < len(parts) && width(lo, hi+1) <= w {
			hi, grew = hi+1, true
		}
		if lo > 0 && width(lo-1, hi) <= w {
			lo, grew = lo-1, true
		}
	}
	s := strings.Join(parts[lo:hi], "")
	if lo > 0 {
		s = "‹" + s
	}
	if hi < len(parts) {
		s += "›"
	}
	return s
}

// detailLines renders exactly h lines of the right pane.
func (m *Model) detailLines(w, h int) []string {
	out := make([]string, h)
	var head, body []string
	switch {
	case m.hc != nil:
		n := m.nodes[m.cursor]
		title, _ := m.detail(n)
		names := tabNames(n.kind)
		active := min(m.tabs[n.kind], len(names)-1)
		title = styleTitle.Render(title)
		if bar := tabBar(names, active, w); ansi.StringWidth(title)+3+ansi.StringWidth(bar) <= w {
			head = []string{title + " ─ " + bar}
		} else {
			head = []string{title, bar}
		}
		body = m.tabBody(n, names[active], w, h-len(head)-1)
	case m.err != nil:
		head = []string{styleBad.Render("flk failed")}
		body = append([]string{"$ " + flk.CommandLine("context", "--all", "--json"), ""}, wrap(m.err.Error(), w)...)
	default:
		head = []string{"loading…"}
		body = []string{"$ " + flk.CommandLine("context", "--all", "--json")}
	}
	copy(out, head)
	room := h - len(head) - 1
	if room <= 0 {
		return out
	}
	m.detailTop = max(min(m.detailTop, len(body)-room), 0)
	shown := body[m.detailTop:min(m.detailTop+room, len(body))]
	if below := len(body) - m.detailTop - room; below > 0 {
		shown = append(shown[:room-1], styleDim.Render(fmt.Sprintf("… %d more (pgdn)", below+1)))
	}
	if m.detailTop > 0 {
		shown[0] = styleDim.Render(fmt.Sprintf("… %d above (pgup)", m.detailTop+1))
	}
	copy(out[len(head)+1:], shown)
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
			if line != "" && ansi.StringWidth(line)+1+ansi.StringWidth(word) > w {
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
