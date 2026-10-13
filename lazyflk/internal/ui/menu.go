package ui

import (
	"fmt"
	"strings"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"

	"lazyflk/internal/actions"
)

// An action goes menu → form (if it has fields) → confirm (if it needs
// one) → job. Each step shows the exact command it will run.

// menuView lists the selection's actions. It rebuilds them on every draw,
// so they follow fresh data (a machine that just stopped can be started).
type menuView struct {
	key    string // node key of the selection it's for
	cursor int
}

type formView struct {
	title string
	act   actions.Action
	vals  map[string]string
	field int
	err   string
}

type confirmView struct {
	title string
	act   actions.Action
	cmd   actions.Command
	typed string
}

// target describes the selection for the action table.
func (m *Model) target(n node) (actions.Target, string, bool) {
	t := actions.Target{StateDir: m.hc.Flk.StateDir}
	var title string
	switch n.kind {
	case kindHost:
		t.Kind, t.Apps, t.Problems = actions.Host, m.apps, m.hc.Host.Problems
		return t, "host", true
	case kindApp, kindMachine, kindVolume, kindPorts:
		t.App = m.apps[n.app]
		title = t.App.Name
	default:
		return t, "", false
	}
	switch n.kind {
	case kindApp:
		t.Kind = actions.App
	case kindMachine:
		t.Kind, t.Machine = actions.Machine, t.App.Machines[n.machine]
		title += " / " + or(t.Machine.Name, t.Machine.ID)
	case kindVolume:
		t.Kind, t.Volume = actions.Volume, t.App.Volumes[n.volume]
		title += " / volume " + t.Volume.Name
		t.Backups, t.BackupsErr = m.backups(t.App.Name)
	case kindPorts:
		t.Kind = actions.Ports
		title += " / ports"
	}
	return t, title, true
}

func (m *Model) selected() (node, bool) {
	if m.hc == nil || m.cursor < 0 || m.cursor >= len(m.nodes) {
		return node{}, false
	}
	return m.nodes[m.cursor], true
}

// menuActions is the open menu's actions, or nil if its selection is gone.
func (m *Model) menuActions() ([]actions.Action, string) {
	n, ok := m.selected()
	if !ok || n.key(m.apps) != m.menu.key {
		return nil, ""
	}
	t, title, ok := m.target(n)
	if !ok {
		return nil, ""
	}
	return actions.For(t), title
}

func (m *Model) openMenu() tea.Cmd {
	if m.opt.ReadOnly {
		m.note = "read-only: actions are off (started with --read-only)"
		return nil
	}
	n, ok := m.selected()
	if !ok || !n.selectable() {
		return nil
	}
	m.menu = &menuView{key: n.key(m.apps)}
	if n.kind == kindVolume { // restore needs the list of backups
		return m.want(m.backupSource(m.apps[n.app].Name))
	}
	return nil
}

func (m *Model) menuKey(msg tea.KeyPressMsg) tea.Cmd {
	acts, title := m.menuActions()
	if acts == nil {
		m.menu = nil
		return nil
	}
	k := msg.String()
	switch k {
	case "esc", "q", "x":
		m.menu = nil
		return nil
	case "up", "k":
		m.menu.cursor = (m.menu.cursor - 1 + len(acts)) % len(acts)
		return nil
	case "down", "j":
		m.menu.cursor = (m.menu.cursor + 1) % len(acts)
		return nil
	case "enter":
		m.menu.cursor = min(m.menu.cursor, len(acts)-1)
		return m.choose(title, acts[m.menu.cursor])
	}
	for i, a := range acts {
		if a.Key == k {
			m.menu.cursor = i
			return m.choose(title, a)
		}
	}
	return nil
}

// choose starts an action picked from a menu, a shortcut or a fix.
func (m *Model) choose(title string, a actions.Action) tea.Cmd {
	if a.Disabled != "" {
		m.note = a.Label + ": " + a.Disabled
		return nil
	}
	m.menu = nil
	if strings.HasPrefix(a.Label, "fix: ") {
		title = "fix ─ " + title
	} else {
		title = a.Label + " ─ " + title
	}
	switch a.View {
	case actions.ViewLogs:
		return m.openLogs()
	case actions.ViewRecord:
		m.setTabNamed("Record")
		return nil
	case actions.ViewHealth:
		m.setTabNamed("Health")
		return nil
	case actions.ViewCopy:
		return m.copy(a.Copy)
	case actions.ViewAttach:
		return m.openAttach()
	case actions.ViewSend:
		return m.openSendLine()
	}
	if j := m.runningJob(); j != nil {
		m.note = "wait for " + j.line + " to finish (L shows it)"
		return nil
	}
	if len(a.Fields) > 0 {
		m.form = &formView{title: title, act: a, vals: map[string]string{}}
		for _, f := range a.Fields {
			m.form.vals[f.Name] = f.Default
			if len(f.Choices) > 0 && f.Default == "" {
				m.form.vals[f.Name] = f.Choices[0]
			}
		}
		return nil
	}
	return m.confirmOrRun(title, a, a.Command(nil))
}

func (m *Model) confirmOrRun(title string, a actions.Action, c actions.Command) tea.Cmd {
	if c.Interactive {
		m.attach = &attachView{title: title, args: c.Args}
		return nil
	}
	if c.TypeName != "" {
		a.Confirm, a.TypeName = actions.Type, c.TypeName
	}
	if a.Confirm == actions.NoConfirm {
		return m.runJob(title, c)
	}
	m.confirm = &confirmView{title: title, act: a, cmd: c}
	return nil
}

func (m *Model) setTabNamed(name string) {
	n, ok := m.selected()
	if !ok {
		return
	}
	for i, t := range tabNames(n.kind) {
		if t == name {
			m.tabs[n.kind] = i
		}
	}
}

// menuBox draws the open menu.
func (m *Model) menuBox() []string {
	acts, title := m.menuActions()
	if acts == nil {
		return nil
	}
	w := min(m.width-4, 84)
	inner := w - 4
	m.menu.cursor = min(m.menu.cursor, len(acts)-1)
	labelW := 0
	for _, a := range acts {
		labelW = max(labelW, ansi.StringWidth(a.Label))
	}
	labelW = min(labelW, inner/2)
	var body []string
	for i, a := range acts {
		key := styleKey.Render(fmt.Sprintf("%-2s", a.Key))
		desc := a.Help
		label := fit(a.Label, labelW)
		if a.Disabled != "" {
			key, label, desc = styleDim.Render(fmt.Sprintf("%-2s", a.Key)), styleDim.Render(label), styleDim.Render(a.Disabled)
		}
		line := key + " " + label + "  " + desc
		if i == m.menu.cursor {
			line = styleSelected.Render(fit(ansi.Strip(line), inner))
		}
		body = append(body, line)
	}
	body = append(body, "")
	cur := acts[m.menu.cursor]
	body = append(body, wrap(cur.Help, inner)...)
	var detail []string
	switch {
	case cur.Disabled != "":
		detail = wrap("not now: "+cur.Disabled, inner)
	case cur.View == actions.ViewCopy:
		detail = wrap("copies: "+cur.Copy, inner)
	case cur.View != "":
		detail = []string{"opens in lazyflk"}
	default:
		detail = wrap("$ "+cur.Command(nil).Line(), inner)
	}
	for i, l := range detail {
		if i > 0 {
			l = "  " + l
		}
		body = append(body, styleDim.Render(l))
	}
	foot := keyHints("↑↓ enter", "choose (or press its key)", "esc", "close")
	if m.note != "" {
		foot = m.note
	}
	return box(title+" ─ actions", body, foot, w)
}

func (m *Model) formKey(msg tea.KeyPressMsg) tea.Cmd {
	f := m.form
	fields := f.act.Fields
	cur := fields[f.field]
	k := msg.String()
	f.err = ""
	switch k {
	case "esc":
		m.form = nil
		return nil
	case "tab", "down":
		f.field = (f.field + 1) % len(fields)
	case "shift+tab", "up":
		f.field = (f.field - 1 + len(fields)) % len(fields)
	case "enter":
		if why := f.act.Check(f.vals); why != "" {
			f.err = why
			return nil
		}
		m.form = nil
		return m.confirmOrRun(f.title, f.act, f.act.Command(f.vals))
	case "left", "right", "space":
		if len(cur.Choices) > 0 {
			i := indexOf(cur.Choices, f.vals[cur.Name])
			if k == "left" {
				i--
			} else {
				i++
			}
			f.vals[cur.Name] = cur.Choices[(i+len(cur.Choices))%len(cur.Choices)]
		} else if k == "space" {
			f.vals[cur.Name] += " "
		}
	case "backspace":
		if v := []rune(f.vals[cur.Name]); len(v) > 0 && len(cur.Choices) == 0 {
			f.vals[cur.Name] = string(v[:len(v)-1])
		}
	case "ctrl+u":
		if len(cur.Choices) == 0 {
			f.vals[cur.Name] = ""
		}
	default:
		if msg.Text != "" && len(cur.Choices) == 0 {
			f.vals[cur.Name] += msg.Text
		}
	}
	return nil
}

// paste adds pasted text to the form's current text field (one line).
func (m *Model) paste(text string) {
	if m.form == nil {
		return
	}
	cur := m.form.act.Fields[m.form.field]
	if len(cur.Choices) == 0 {
		text = strings.TrimRight(text, "\r\n")
		text = strings.NewReplacer("\r", "", "\n", "").Replace(text)
		m.form.vals[cur.Name] += text
	}
}

func indexOf(xs []string, s string) int {
	for i, x := range xs {
		if x == s {
			return i
		}
	}
	return 0
}

func (m *Model) formBox() []string {
	f := m.form
	w := min(m.width-4, 84)
	inner := w - 4
	labelW := 0
	for _, fl := range f.act.Fields {
		labelW = max(labelW, ansi.StringWidth(fl.Label))
	}
	body := wrap(f.act.Help, inner)
	var notes []string
	for _, n := range f.act.Notes {
		for i, l := range wrap(n, inner-2) {
			p := "· "
			if i > 0 {
				p = "  "
			}
			notes = append(notes, styleDim.Render(p+l))
		}
	}
	notesAt := len(body)
	body = append(body, "")
	for i, fl := range f.act.Fields {
		v := f.vals[fl.Name]
		var shown string
		switch {
		case len(fl.Choices) > 0:
			shown = "‹ " + v + " ›"
		case fl.Secret:
			shown = strings.Repeat("•", len([]rune(v)))
		default:
			shown = v
		}
		if i == f.field && len(fl.Choices) == 0 {
			shown += "▏"
		}
		boxW := inner - labelW - 1
		if len(fl.Choices) == 0 {
			shown = "[" + fit(ansi.TruncateLeft(shown, max(ansi.StringWidth(shown)-(boxW-2), 0), "…"), boxW-2) + "]"
		}
		label := fit(fl.Label, labelW)
		if i == f.field {
			label = styleSelected.Render(label)
		}
		body = append(body, label+" "+shown)
		if i == f.field && fl.Help != "" {
			for _, l := range wrap(fl.Help, boxW) {
				body = append(body, strings.Repeat(" ", labelW+1)+styleDim.Render(l))
			}
		}
	}
	body = append(body, "")
	for i, l := range wrap("$ "+f.act.Command(f.vals).Line(), inner) {
		if i > 0 {
			l = "  " + l
		}
		body = append(body, styleDim.Render(l))
	}
	if f.err != "" {
		body = append(body, styleBad.Render("! "+f.err))
	}
	keys := []string{"tab ↑↓", "field"}
	for _, fl := range f.act.Fields {
		if len(fl.Choices) > 0 {
			keys = append(keys, "←→", "choose")
			break
		}
	}
	foot := keyHints(append(keys, "enter", "next step", "esc", "cancel")...)
	// notes fill the room that's left; the form itself always shows
	if room := m.height - 6 - len(body); room > 0 && len(notes) > 0 {
		if len(notes) > room {
			notes = append(notes[:room-1], styleDim.Render("  … (flk help "+f.act.Label+")"))
		}
		body = append(body[:notesAt], append(notes, body[notesAt:]...)...)
	}
	return box(f.title, body, foot, w)
}

func (m *Model) confirmKey(msg tea.KeyPressMsg) tea.Cmd {
	c := m.confirm
	k := msg.String()
	if c.act.Confirm == actions.Type {
		switch k {
		case "esc":
			m.confirm = nil
		case "enter":
			if c.typed == c.act.TypeName {
				m.confirm = nil
				return m.runJob(c.title, c.cmd)
			}
		case "backspace":
			if r := []rune(c.typed); len(r) > 0 {
				c.typed = string(r[:len(r)-1])
			}
		default:
			c.typed += msg.Text
		}
		return nil
	}
	switch k {
	case "y", "Y":
		m.confirm = nil
		return m.runJob(c.title, c.cmd)
	case "n", "N", "esc", "q":
		m.confirm = nil
	}
	return nil
}

func (m *Model) confirmBox() []string {
	c := m.confirm
	w := min(m.width-4, 84)
	inner := w - 4
	var body []string
	for i, l := range wrap("$ "+c.cmd.Line(), inner) {
		if i > 0 {
			l = "  " + l
		}
		body = append(body, styleTitle.Render(l))
	}
	if c.cmd.Warn != "" {
		body = append(body, "")
		body = append(body, wrap(c.cmd.Warn, inner)...)
	}
	body = append(body, "")
	var foot string
	if c.act.Confirm == actions.Type {
		prompt := "Type " + c.act.TypeName + " to confirm: "
		mark := ""
		if c.typed == c.act.TypeName {
			mark = styleOK.Render(" ✔ enter runs it")
		}
		body = append(body, styleBad.Render(prompt)+c.typed+"▏"+mark)
		foot = keyHints("enter", "run (once it matches)", "esc", "cancel")
	} else {
		body = append(body, styleWarn.Render("Run it?"))
		foot = keyHints("y", "run", "n esc", "cancel")
	}
	return box(c.title, body, foot, w)
}
