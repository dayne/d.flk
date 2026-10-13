package ui

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"

	"lazyflk/internal/flk"
)

// Events (G7, flk c0a98f4): one `flk events --all --json --follow` for
// the whole session. A live event reloads the main view at once, so
// polling drops to a slow backstop while the stream is up; the Events
// tabs show the history.
const (
	eventKeep     = 500              // events kept for the tabs
	eventHistory  = 200              // asked for when the stream starts
	eventBackstop = 30 * time.Second // full reload while events flow
	eventRetry    = 5 * time.Second  // reconnect after the stream ends
)

type eventFeed struct {
	gen     int
	stream  *flk.Stream
	alive   bool
	off     string // why there are no events (flk too old), "" if there are
	list    []flk.Event
	last    string          // the newest event's time, for --since
	atLast  map[string]bool // lines at that time, to drop repeats
	started time.Time
	err     string
}

type eventStartMsg struct {
	gen    int
	stream *flk.Stream
	err    error
}

type eventChunkMsg struct {
	gen   int
	lines []flk.Line
	done  bool
}

type eventRetryMsg struct{ gen int }

// eventArgs is the stream's command: history first, or everything since
// the last event seen after a reconnect.
func (f *eventFeed) eventArgs() []string {
	args := []string{"events", "--all", "--json", "--follow"}
	if f.last != "" {
		return append(args, "--since", f.last)
	}
	return append(args, "-n", fmt.Sprint(eventHistory))
}

func (m *Model) startEvents() tea.Cmd {
	if m.ev == nil {
		m.ev = &eventFeed{atLast: map[string]bool{}}
	}
	f := m.ev
	f.gen++
	f.started = m.now()
	c, args, gen := m.opt.Client, f.eventArgs(), f.gen
	return func() tea.Msg {
		s, err := c.Stream(context.Background(), args...)
		return eventStartMsg{gen, s, err}
	}
}

func (m *Model) stopEvents() {
	if m.ev != nil && m.ev.stream != nil {
		m.ev.stream.Stop()
		m.ev.stream, m.ev.alive = nil, false
	}
}

func (m *Model) eventStart(msg eventStartMsg) tea.Cmd {
	f := m.ev
	if f == nil || msg.gen != f.gen {
		if msg.stream != nil {
			msg.stream.Stop()
		}
		return nil
	}
	if msg.err != nil {
		f.err = msg.err.Error()
		return m.retryEvents()
	}
	f.stream, f.alive, f.err = msg.stream, true, ""
	return readLines(msg.stream, func(lines []flk.Line, done bool) tea.Msg { return eventChunkMsg{msg.gen, lines, done} })
}

func (m *Model) eventChunk(msg eventChunkMsg) tea.Cmd {
	f := m.ev
	if f == nil || msg.gen != f.gen || f.stream == nil {
		return nil
	}
	apps := map[string]bool{}
	for _, l := range msg.lines {
		var e flk.Event
		if json.Unmarshal([]byte(l.Text), &e) != nil || e.Type == "" {
			continue // flk's stderr, or a line it may add later
		}
		if e.At == f.last && f.atLast[l.Text] {
			continue // seen before a reconnect (--since is >=)
		}
		if e.At != f.last {
			f.last, f.atLast = e.At, map[string]bool{}
		}
		f.atLast[l.Text] = true
		f.list = append(f.list, e)
		if t, err := time.Parse(time.RFC3339, e.At); err == nil && !t.Before(f.started.Add(-2*time.Second)) {
			apps[e.App] = true // live, not history
		}
	}
	if drop := len(f.list) - eventKeep; drop > 0 {
		f.list = append([]flk.Event(nil), f.list[drop:]...)
	}
	var cmds []tea.Cmd
	if len(apps) > 0 {
		cmds = append(cmds, m.eventsChanged(apps))
	}
	if msg.done {
		err := f.stream.Err()
		f.stream, f.alive = nil, false
		if err != nil && len(f.list) == 0 && strings.Contains(err.Error(), "events") {
			f.off = "this flk has no events (" + firstLine(err.Error()) + "): polling every " + m.opt.Refresh.String()
			return tea.Batch(cmds...)
		}
		if err != nil {
			f.err = firstLine(err.Error())
		}
		return tea.Batch(append(cmds, m.retryEvents())...)
	}
	return tea.Batch(append(cmds, readLines(f.stream, func(lines []flk.Line, done bool) tea.Msg {
		return eventChunkMsg{msg.gen, lines, done}
	}))...)
}

func (m *Model) retryEvents() tea.Cmd {
	if m.opt.Refresh <= 0 { // load once (tests): no reconnects
		return nil
	}
	gen := m.ev.gen
	return tea.Tick(eventRetry, func(time.Time) tea.Msg { return eventRetryMsg{gen} })
}

// eventsChanged reloads what live events touched: the main view now, and
// the apps' cached tab data (releases, backups, logs…) when next shown.
func (m *Model) eventsChanged(apps map[string]bool) tea.Cmd {
	for key := range m.cache {
		for app := range apps {
			if strings.Contains(key, " -a "+app+" ") || strings.HasPrefix(key, "flk -a "+app+" ") {
				delete(m.cache, key)
			}
		}
	}
	if src := m.diskUseSource(); src != nil {
		delete(m.cache, src.cmd)
	}
	if m.loading {
		m.reloadAgain = true
		return nil
	}
	return m.reload()
}

// eventsLive reports whether events are flowing, so polling can slow down.
func (m *Model) eventsLive() bool { return m.ev != nil && m.ev.alive }

// eventLines lists events newest first: all of them, an app's, or a
// machine's.
func (m *Model) eventLines(app, machine string, w int) []string {
	f := m.ev
	var out []string
	switch {
	case f == nil:
		return []string{styleDim.Render("starting flk events…")}
	case f.off != "":
		return wrap(f.off, w)
	case f.alive:
		out = append(out, styleDim.Render("$ "+flk.CommandLine("events", "--all", "--json", "--follow")+"  (live)"))
	default:
		out = append(out, styleWarn.Render("events stream down"+or(": "+f.err, "")+"; reconnecting, polling meanwhile"))
	}
	out = append(out, "")
	n := 0
	for i := len(f.list) - 1; i >= 0; i-- {
		e := f.list[i]
		if (app != "" && e.App != app) || (machine != "" && e.Machine != machine) {
			continue
		}
		out = append(out, m.eventLine(e, app == ""))
		n++
	}
	if n == 0 {
		out = append(out, styleDim.Render("no events yet"))
	}
	return out
}

func (m *Model) eventLine(e flk.Event, withApp bool) string {
	at := e.At
	if t, err := time.Parse(time.RFC3339, e.At); err == nil {
		at = t.Local().Format("01-02 15:04:05")
		if m.now().Sub(t) < 20*time.Hour {
			at = t.Local().Format("15:04:05")
		}
	}
	who := ""
	if withApp {
		who = e.App
	}
	if e.Machine != "" {
		name := e.Machine
		for _, a := range m.apps {
			for _, mc := range a.Machines {
				if a.Name == e.App && mc.ID == e.Machine && mc.Name != "" {
					name = mc.Name
				}
			}
		}
		who = strings.TrimPrefix(who+" / "+name, " / ")
	}
	s := fmt.Sprintf("%-8s  %s", at, eventStyle(e.Type))
	if e.Release > 0 {
		s += fmt.Sprintf(" v%d", e.Release)
	}
	if who != "" {
		s += "  " + styleDim.Render(who)
	}
	if e.Detail != "" {
		s += "  " + e.Detail
	}
	return s
}

// eventStyle colours a type by how it went. Every boot is one of
// created, started, updated, restarted or rolled_back; the last two
// follow a failure, so they're a warning.
func eventStyle(t string) string {
	switch {
	case strings.HasSuffix(t, "failed"), t == "machine.gave_up":
		return styleBad.Render(t)
	case t == "machine.exited", t == "machine.rolled_back", t == "machine.restarted", t == "port.dropped":
		return styleWarn.Render(t)
	case strings.HasSuffix(t, "succeeded"), strings.HasSuffix(t, "passed"),
		t == "machine.started", t == "machine.created", t == "machine.updated":
		return styleOK.Render(t)
	}
	return t
}
