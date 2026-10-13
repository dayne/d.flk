package ui

import (
	"fmt"
	"sort"
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

// guideView browses flk's guides (SPEC 5.6): `flk help TOPIC`, so the
// docs always match the installed flk.
type guideView struct {
	cursor  int
	topic   string // open topic, "" for the list
	top     int
	query   string
	editing bool
	input   string
	match   int
}

// guideOrder is the order a new admin reads them in; topics flk adds
// later follow, by name.
var guideOrder = []string{"cheatsheet", "install", "first-app", "operate", "troubleshoot", "uninstall"}

func (m *Model) topics() []string {
	h, ok := m.flkHelp()
	if !ok {
		return nil
	}
	var out, rest []string
	for _, t := range guideOrder {
		if _, ok := h.Topics[t]; ok {
			out = append(out, t)
		}
	}
	for t := range h.Topics {
		if !strings.Contains(" "+strings.Join(guideOrder, " ")+" ", " "+t+" ") {
			rest = append(rest, t)
		}
	}
	sort.Strings(rest)
	return append(out, rest...)
}

func (m *Model) openGuides() tea.Cmd {
	m.guides = &guideView{match: -1}
	return m.want(m.helpSource())
}

func (m *Model) guideSource(topic string) *source {
	return m.textSource([]string{"help", topic}, time.Hour)
}

// guideLines is the open topic's text, or nil while it loads.
func (m *Model) guideLines() ([]string, string) {
	src := m.guideSource(m.guides.topic)
	f := m.cache[src.cmd]
	switch {
	case f == nil || (f.val == nil && f.err == nil):
		return nil, "loading…"
	case f.val == nil:
		return nil, f.err.Error()
	}
	return strings.Split(strings.TrimRight(cleanText(f.val.(string)), "\n"), "\n"), ""
}

func (m *Model) guideKey(msg tea.KeyPressMsg) tea.Cmd {
	g := m.guides
	k := msg.String()
	if g.topic == "" {
		topics := m.topics()
		switch k {
		case "esc", "q", "H":
			m.guides = nil
		case "up", "k":
			g.cursor = max(g.cursor-1, 0)
		case "down", "j":
			g.cursor = min(g.cursor+1, max(len(topics)-1, 0))
		case "enter", "right", "l":
			if len(topics) > 0 {
				g.topic, g.top, g.query, g.match = topics[g.cursor], 0, "", -1
				return m.want(m.guideSource(g.topic))
			}
		}
		return nil
	}
	lines, _ := m.guideLines()
	page := max(m.height-6, 1)
	if g.editing {
		switch k {
		case "enter":
			g.editing, g.query = false, g.input
			g.match = -1
			g.find(lines, 1, page)
		case "esc":
			g.editing = false
		case "backspace":
			if r := []rune(g.input); len(r) > 0 {
				g.input = string(r[:len(r)-1])
			}
		case "space":
			g.input += " "
		default:
			g.input += msg.Text
		}
		return nil
	}
	switch k {
	case "esc", "q", "left", "h":
		g.topic = ""
	case "up", "k":
		g.top--
	case "down", "j":
		g.top++
	case "pgup", "ctrl+u", "ctrl+b":
		g.top -= page
	case "pgdown", "ctrl+d", "ctrl+f", "space":
		g.top += page
	case "g", "home":
		g.top = 0
	case "G", "end":
		g.top = len(lines)
	case "/":
		g.editing, g.input = true, g.query
	case "n":
		g.find(lines, 1, page)
	case "N":
		g.find(lines, -1, page)
	}
	g.top = max(min(g.top, len(lines)-page), 0)
	return nil
}

// find moves to the next (dir 1) or previous match of the query.
func (g *guideView) find(lines []string, dir, page int) {
	if g.query == "" || len(lines) == 0 {
		return
	}
	q := strings.ToLower(g.query)
	start := g.match
	if start < 0 {
		start = g.top - 1
		if dir < 0 {
			start = g.top + page
		}
	}
	for i := 1; i <= len(lines); i++ {
		j := ((start+dir*i)%len(lines) + len(lines)) % len(lines)
		if strings.Contains(strings.ToLower(lines[j]), q) {
			g.match = j
			if j < g.top || j >= g.top+page {
				g.top = max(j-page/3, 0)
			}
			return
		}
	}
	g.match = -1
}

func (m *Model) guideScreen() string {
	g := m.guides
	w, h := m.width, m.height
	inner, room := w-4, h-4
	var body []string
	var title, foot string
	if g.topic == "" {
		title = "Guides ─ flk help TOPIC"
		help, ok := m.flkHelp()
		if !ok {
			body = append(body, styleDim.Render("loading flk's topics (flk help --all --json)…"))
		}
		topics := m.topics()
		g.cursor = min(g.cursor, max(len(topics)-1, 0))
		for i, t := range topics {
			line := fit(t, 14) + "  " + styleDim.Render(help.Topics[t])
			if i == g.cursor {
				line = styleSelected.Render(fit(ansi.Strip(line), inner))
			}
			body = append(body, line)
		}
		body = append(body, "", styleDim.Render("Each is `flk help TOPIC`, from the flk you have. flk help --all is the full reference;"),
			styleDim.Render("the command palette (:) has every command."))
		foot = keyHints("↑↓", "choose", "enter", "read", "esc", "back")
	} else {
		title = "Guide ─ flk help " + g.topic
		lines, status := m.guideLines()
		if lines == nil {
			body = append(body, styleDim.Render("$ flk help "+g.topic), "", status)
		}
		for i := g.top; i < len(lines) && len(body) < room; i++ {
			l := lines[i]
			if g.query != "" {
				l = highlight(l, g.query)
			}
			if i == g.match {
				l = styleSelected.Render(ansi.Strip(l))
			}
			body = append(body, l)
		}
		if len(lines) > room {
			title += fmt.Sprintf(" ─ %d%%", min(100, (g.top+room)*100/len(lines)))
		}
		foot = keyHints("↑↓ pgup/dn", "scroll", "/", "search", "n/N", "match", "esc", "topics")
		if g.editing {
			foot = "/" + g.input + "█" + styleDim.Render("   enter search · esc cancel")
		} else if g.query != "" && g.match < 0 {
			foot = styleWarn.Render(fmt.Sprintf("no match for %q", g.query))
		}
	}
	for len(body) < room {
		body = append(body, "")
	}
	return strings.Join(box(title, body, foot, w), "\n")
}
