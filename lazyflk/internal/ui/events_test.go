package ui

import (
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"lazyflk/internal/flk"
)

func eventLine(at time.Time, app, typ string) flk.Line {
	return flk.Line{Text: fmt.Sprintf(`{"at":%q,"app":%q,"machine":"225d58f615e7e6","type":%q,"release":9}`,
		at.UTC().Format("2006-01-02T15:04:05.000Z"), app, typ)}
}

// History fills the Events tabs without reloading anything; a live event
// reloads the main view and drops the app's cached tab data.
func TestEventsFeed(t *testing.T) {
	m := demoModel(t, 160, 48)
	now := time.Date(2026, 10, 14, 12, 0, 0, 0, time.UTC)
	m.now = func() time.Time { return now }
	send(m, runCmd(m.startEvents())...)
	f := m.ev
	if f == nil || len(f.list) != 60 || !f.alive || f.last == "" {
		t.Fatalf("history: %+v", f)
	}
	if calls := fmt.Sprint(m.opt.Client.Runner.(*flk.Fake).Calls()); !strings.Contains(calls, "[events --all --json --follow -n 200]") {
		t.Errorf("calls %s", calls)
	}
	goTo(m, kindHost)
	press(m, "2")
	s := screen(m)
	if !strings.Contains(s, "flk events --all --json --follow  (live)") || !strings.Contains(s, "deploy.succeeded") {
		t.Errorf("host events:\n%s", s)
	}

	gen := m.loadGen
	m.cache["flk -a minecraft-flk releases --json"] = &fetched{val: []flk.Release{}, at: now}
	m.cache["flk -a vintagestory-flk releases --json"] = &fetched{val: []flk.Release{}, at: now}
	send(m, eventChunkMsg{gen: f.gen, lines: []flk.Line{eventLine(now, "minecraft-flk", "machine.exited")}})
	if m.loadGen == gen {
		t.Error("a live event reloads")
	}
	if m.cache["flk -a minecraft-flk releases --json"] != nil || m.cache["flk -a vintagestory-flk releases --json"] == nil {
		t.Error("only the event's app is refetched")
	}
	if s := screen(m); !strings.Contains(s, "machine.exited v9  minecraft-flk / mellow-aurora-7882") {
		t.Errorf("newest first, with the machine's name:\n%s", s)
	}

	// while events flow, polling only backs them up
	m.opt.Refresh = 5 * time.Second
	m.loading, m.lastLoad = false, now
	gen = m.loadGen
	send(m, tickMsg{})
	if m.loadGen != gen {
		t.Error("no poll right after a load while events are live")
	}
	now = now.Add(eventBackstop)
	send(m, tickMsg{})
	if m.loadGen == gen {
		t.Error("the backstop reload")
	}
}

// After a reconnect --since repeats the newest time's events; they're
// dropped. A flk without events says so and polling carries on.
func TestEventsReconnect(t *testing.T) {
	m := demoModel(t, 120, 40)
	now := time.Date(2026, 10, 14, 12, 0, 0, 0, time.UTC)
	m.now = func() time.Time { return now }
	m.ev = &eventFeed{atLast: map[string]bool{}, gen: 1, alive: true, stream: flk.TextStream(t.Context(), "", true)}
	l := eventLine(now, "minecraft-flk", "backup.succeeded")
	send(m, eventChunkMsg{gen: 1, lines: []flk.Line{l}})
	send(m, eventChunkMsg{gen: 1, lines: []flk.Line{l, eventLine(now, "minecraft-flk", "backup.copied")}})
	if len(m.ev.list) != 2 {
		t.Errorf("%d events: %+v", len(m.ev.list), m.ev.list)
	}
	if args := strings.Join(m.ev.eventArgs(), " "); args != "events --all --json --follow --since "+m.ev.last {
		t.Error(args)
	}

	old := demoModel(t, 120, 40)
	old.ev = &eventFeed{atLast: map[string]bool{}, gen: 1, alive: true,
		stream: flk.EndedStream(errors.New("Error: unknown command 'events' (see: flk help)"))}
	send(old, eventChunkMsg{gen: 1, done: true})
	if old.ev.off == "" || old.eventsLive() {
		t.Errorf("old flk: %+v", old.ev)
	}
	if got := strings.Join(old.eventLines("", "", 100), "\n"); !strings.Contains(got, "this flk has no events") {
		t.Error(got)
	}
}
