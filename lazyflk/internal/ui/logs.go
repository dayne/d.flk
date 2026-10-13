package ui

import (
	"context"
	"fmt"
	"strconv"
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"

	"lazyflk/internal/flk"
)

const (
	logBacklog = 1000  // lines flk prints before following
	logMax     = 20000 // lines kept in memory
)

// logsView follows `flk logs -f` for one machine or all of an app's
// machines (SPEC 5.2). Output arrives in chunks from a background stream.
type logsView struct {
	client   *flk.Client
	app      string
	machines []flk.Machine
	sel      int // index into machines; -1 for all of them

	lines  []logLine
	follow bool // stick to the bottom
	top    int  // first line shown when not following
	wrap   bool

	query   string // search
	editing bool
	input   string
	match   int // line of the current match, -1 for none
	note    string

	// a host command's output instead of flk logs (journalctl, podman logs)
	prog  string
	fixed []string
	title string

	// banner pins the latest reboot or log rotation seen while watching
	// (not in the history loaded at open), until dismissed with x
	banner  string
	started time.Time
	now     func() time.Time

	canSend bool   // > types a line into the machine's console (not read-only)
	sending bool   // the > prompt is open
	line    string // what's typed at it

	gen    int // bumped per stream so late chunks from an old one are dropped
	stream *flk.Stream
	ended  bool
	err    error
}

// sendLineMsg asks the model to run `flk console ID --send TEXT`.
type sendLineMsg struct {
	v       *logsView
	app, id string
	text    string
}

type logStartMsg struct {
	v      *logsView
	gen    int
	stream *flk.Stream
	err    error
}

type logChunkMsg struct {
	v     *logsView
	gen   int
	lines []flk.Line
	done  bool
}

func newLogsView(c *flk.Client, app string, machines []flk.Machine, sel int) *logsView {
	return &logsView{client: c, app: app, machines: machines, sel: sel, match: -1}
}

// newCommandLogs follows another program's output (a provider's logs).
func newCommandLogs(c *flk.Client, prog string, args []string, title string) *logsView {
	return &logsView{client: c, prog: prog, fixed: args, title: title, match: -1}
}

// commandLine is what the view runs, as shown.
func (v *logsView) commandLine() string {
	if v.prog != "" {
		return flk.CommandLineFor(v.prog, v.args()...)
	}
	return flk.CommandLine(v.args()...)
}

func (v *logsView) args() []string {
	if v.fixed != nil {
		return v.fixed
	}
	args := []string{"-a", v.app, "logs"}
	if v.sel >= 0 {
		args = append(args, "-i", v.machines[v.sel].ID)
	}
	return append(args, "-n", strconv.Itoa(logBacklog), "-f")
}

func (v *logsView) target() string {
	if v.fixed != nil {
		return v.title
	}
	if v.sel < 0 {
		if len(v.machines) == 1 {
			return or(v.machines[0].Name, v.machines[0].ID)
		}
		return "all machines"
	}
	return or(v.machines[v.sel].Name, v.machines[v.sel].ID)
}

func (v *logsView) machineName(id string) string {
	for _, m := range v.machines {
		if m.ID == id && m.Name != "" {
			return m.Name + " (" + id + ")"
		}
	}
	return id
}

// start (re)starts the stream for the current machine selection.
func (v *logsView) start() tea.Cmd {
	v.stop()
	v.gen++
	v.lines, v.top, v.follow, v.match, v.ended, v.err, v.note = nil, 0, true, -1, false, nil, ""
	v.banner, v.started = "", v.clock()
	c, args, gen := v.client, v.args(), v.gen
	return func() tea.Msg {
		s, err := c.Stream(context.Background(), args...)
		return logStartMsg{v, gen, s, err}
	}
}

func (v *logsView) stop() {
	if v.stream != nil {
		v.stream.Stop()
		v.stream = nil
	}
}

// readChunk waits for the next output and returns everything already
// waiting with it, so a burst renders once.
func readChunk(v *logsView, gen int, s *flk.Stream) tea.Cmd {
	return readLines(s, func(lines []flk.Line, done bool) tea.Msg { return logChunkMsg{v, gen, lines, done} })
}

// readLines waits for a stream's next lines, taking what's buffered in one
// go, and wraps them in a message; done means the stream has ended.
func readLines(s *flk.Stream, msg func(lines []flk.Line, done bool) tea.Msg) tea.Cmd {
	return func() tea.Msg {
		l, ok := <-s.Lines
		if !ok {
			return msg(nil, true)
		}
		lines := []flk.Line{l}
		for len(lines) < 2000 {
			select {
			case l, ok := <-s.Lines:
				if !ok {
					return msg(lines, true)
				}
				lines = append(lines, l)
			default:
				return msg(lines, false)
			}
		}
		return msg(lines, false)
	}
}

func (v *logsView) handleStart(msg logStartMsg) tea.Cmd {
	if msg.gen != v.gen {
		if msg.stream != nil {
			msg.stream.Stop()
		}
		return nil
	}
	if msg.err != nil {
		v.ended, v.err = true, msg.err
		return nil
	}
	v.stream = msg.stream
	return readChunk(v, v.gen, msg.stream)
}

func (v *logsView) handleChunk(msg logChunkMsg) tea.Cmd {
	if msg.gen != v.gen || v.stream == nil {
		return nil
	}
	live := v.clock().Sub(v.started) > 2*time.Second // past the history -n loads
	for _, l := range msg.lines {
		ll := classifyLog(l, v.machineName)
		v.lines = append(v.lines, ll)
		if live && ll.kind == logBanner {
			v.banner = v.clock().Format("15:04") + "  " + ll.text
		}
	}
	if drop := len(v.lines) - logMax; drop > 0 {
		v.lines = append([]logLine(nil), v.lines[drop:]...)
		v.top = max(v.top-drop, 0)
		if v.match >= 0 {
			v.match -= drop
		}
	}
	if msg.done {
		v.ended, v.err = true, v.stream.Err()
		v.stream = nil
		return nil
	}
	return readChunk(v, v.gen, v.stream)
}

// rows renders line i as screen rows of width w.
func (v *logsView) rows(i, w int) []string {
	l := v.lines[i]
	text := l.text
	if !v.wrap || ansi.StringWidth(text) <= w {
		return []string{v.paint(l, ansi.Truncate(text, w, "…"), i)}
	}
	var out []string
	for _, part := range strings.Split(ansi.Hardwrap(text, w, true), "\n") {
		out = append(out, v.paint(l, part, i))
	}
	return out
}

func (v *logsView) paint(l logLine, text string, i int) string {
	if v.query != "" && l.kind == logText {
		if i == v.match {
			return styleSelected.Render(text)
		}
		return highlight(text, v.query)
	}
	l.text = text
	return l.styled()
}

// bottomTop is the first line shown when following: the last page.
func (v *logsView) bottomTop(w, h int) int {
	n := 0
	for i := len(v.lines) - 1; i >= 0; i-- {
		n += len(v.rows(i, w))
		if n > h {
			return i + 1
		}
	}
	return 0
}

func (v *logsView) firstShown(w, h int) int {
	if v.follow {
		return v.bottomTop(w, h)
	}
	return v.top
}

func (v *logsView) scroll(delta, w, h int) {
	bottom := v.bottomTop(w, h)
	v.top = max(min(v.firstShown(w, h)+delta, bottom), 0)
	v.follow = v.top >= bottom && delta > 0
}

// find moves to the next (dir 1) or previous (dir -1) match from the
// current one, or from the view when there is none.
func (v *logsView) find(dir, w, h int) {
	if v.query == "" {
		return
	}
	from := v.match
	if from < 0 {
		from = v.firstShown(w, h) - 1
		if dir < 0 {
			from = len(v.lines)
		}
	}
	q := strings.ToLower(v.query)
	for n, i := 0, from+dir; n < len(v.lines); n, i = n+1, i+dir {
		i = (i + len(v.lines)) % len(v.lines)
		if v.lines[i].kind == logText && strings.Contains(v.lines[i].lower, q) {
			v.match, v.follow, v.note = i, false, ""
			v.top = max(min(i-h/3, v.bottomTop(w, h)), 0)
			return
		}
	}
	v.match, v.note = -1, "no match for "+strconv.Quote(v.query)
}

func (v *logsView) matchCount() (pos, total int) {
	q := strings.ToLower(v.query)
	for i, l := range v.lines {
		if l.kind == logText && strings.Contains(l.lower, q) {
			total++
			if i <= v.match {
				pos = total
			}
		}
	}
	return pos, total
}

// key handles a key press; it reports false when the view should close.
// sendTarget is the machine > types into: the one shown, or the app's
// only machine.
func (v *logsView) sendTarget() (flk.Machine, bool) {
	switch {
	case v.sel >= 0 && v.sel < len(v.machines):
		return v.machines[v.sel], true
	case len(v.machines) == 1:
		return v.machines[0], true
	}
	return flk.Machine{}, false
}

func (v *logsView) openSend() {
	switch _, ok := v.sendTarget(); {
	case !v.canSend:
		v.note = "read-only: sending to the console is off"
	case !ok:
		v.note = "a line goes to one machine: pick it with [ ]"
	default:
		v.sending, v.line = true, ""
	}
}

func (v *logsView) clock() time.Time {
	if v.now != nil {
		return v.now()
	}
	return time.Now()
}

func (v *logsView) key(msg tea.KeyPressMsg, w, h int) (tea.Cmd, bool) {
	if v.banner != "" {
		h-- // the banner takes a row
	}
	if v.sending {
		switch msg.String() {
		case "enter":
			mc, _ := v.sendTarget()
			text := v.line
			v.sending, v.follow = false, true
			if strings.TrimSpace(text) == "" {
				return nil, true
			}
			v.note = "sending: " + text
			return func() tea.Msg { return sendLineMsg{v, v.app, mc.ID, text} }, true
		case "esc":
			v.sending = false
		case "backspace":
			if r := []rune(v.line); len(r) > 0 {
				v.line = string(r[:len(r)-1])
			}
		case "ctrl+u":
			v.line = ""
		case "space":
			v.line += " "
		default:
			v.line += msg.Text
		}
		return nil, true
	}
	if v.editing {
		switch msg.String() {
		case "enter":
			v.editing, v.query, v.match = false, v.input, -1
			v.find(-1, w, h) // the most recent match first
		case "esc":
			v.editing = false
		case "backspace":
			if r := []rune(v.input); len(r) > 0 {
				v.input = string(r[:len(r)-1])
			}
		case "ctrl+u":
			v.input = ""
		default:
			if msg.Text != "" {
				v.input += msg.Text
			}
		}
		return nil, true
	}
	v.note = ""
	switch msg.String() {
	case "esc", "q":
		v.stop()
		return nil, false
	case "f":
		if v.follow {
			v.top, v.follow = v.bottomTop(w, h), false
		} else {
			v.follow = true
		}
	case "w":
		v.wrap = !v.wrap
	case "/":
		v.editing, v.input = true, v.query
	case ">":
		v.openSend()
	case "x":
		v.banner = ""
	case "n":
		v.find(1, w, h)
	case "N":
		v.find(-1, w, h)
	case "g", "home":
		v.top, v.follow = 0, false
	case "G", "end":
		v.follow = true
	case "up", "k":
		v.scroll(-1, w, h)
	case "down", "j":
		v.scroll(1, w, h)
	case "pgup", "ctrl+b":
		v.scroll(-h, w, h)
	case "pgdown", "ctrl+f", "space":
		v.scroll(h, w, h)
	case "[", "]":
		if len(v.machines) > 1 {
			step := 1
			if msg.String() == "[" {
				step = -1
			}
			// -1 (all), 0 .. n-1, cycling
			v.sel = (v.sel+1+step+len(v.machines)+1)%(len(v.machines)+1) - 1
			return v.start(), true
		}
	}
	return nil, true
}

// render draws the log screen at w x h.
func (v *logsView) render(w, h int) string {
	bw, bh := w-4, h-5
	if v.banner != "" {
		bh--
	}
	var b strings.Builder
	line := func(s string) { b.WriteString(s + "\n") }

	var status []string
	switch {
	case v.err != nil:
		status = append(status, "ended with an error")
	case v.ended:
		status = append(status, "ended")
	case v.follow:
		status = append(status, "following")
	default:
		status = append(status, "paused")
	}
	if v.query != "" {
		pos, total := v.matchCount()
		status = append(status, fmt.Sprintf("/%s %d/%d", v.query, pos, total))
	}
	if v.wrap {
		status = append(status, "wrap")
	}
	right := " " + strings.Join(status, " · ") + " "
	title := "Logs ─ " + v.app + " / " + v.target()
	if v.fixed != nil {
		title = "Logs ─ " + v.title
	}
	line("┌" + rule(title, w-2-ansi.StringWidth(right)) + right + "┐")
	line("│ " + fit(styleDim.Render("$ "+v.commandLine()), w-4) + " │")
	if v.banner != "" {
		line("│ " + fit(styleWarn.Render("⚑ "+v.banner), w-4) + " │")
	}

	var rows []string
	for i := v.firstShown(bw, bh); i < len(v.lines) && len(rows) < bh; i++ {
		rows = append(rows, v.rows(i, bw)...)
	}
	if len(v.lines) == 0 {
		msg := "waiting for output…"
		if v.ended {
			msg = "no output"
		}
		rows = append(rows, styleDim.Render(msg))
	}
	if v.err != nil {
		for _, l := range wrap(v.err.Error(), bw) {
			rows = append(rows, styleBad.Render(l))
		}
	}
	if len(rows) > bh {
		if v.follow || v.err != nil { // the newest rows, and the error
			rows = rows[len(rows)-bh:]
		} else {
			rows = rows[:bh]
		}
	}
	for i := range bh {
		s := ""
		if i < len(rows) {
			s = rows[i]
		}
		line("│ " + fit(s, bw) + " │")
	}
	line("├" + rule("", w-2) + "┤")
	hints := []string{"f", "follow", "/", "search", "n/N", "match", "w", "wrap", "g/G", "top/end"}
	if len(v.machines) > 1 {
		hints = append(hints, "[ ]", "machine")
	}
	if v.banner != "" {
		hints = append([]string{"x", "dismiss ⚑"}, hints...)
	}
	if _, ok := v.sendTarget(); ok && v.canSend {
		hints = append(hints, ">", "send a line")
	}
	foot := keyHints(append(hints, "esc", "back", "?", "help")...)
	switch {
	case v.sending:
		mc, _ := v.sendTarget()
		foot = styleKey.Render("> ") + v.line + "█" + styleDim.Render("   enter: type it into "+or(mc.Name, mc.ID)+"'s console · esc cancel")
	case v.editing:
		foot = "/" + v.input + "█" + styleDim.Render("   enter search · esc cancel")
	case v.note != "":
		foot = styleWarn.Render(v.note)
	}
	line("│ " + fit(foot, w-4) + " │")
	b.WriteString("└" + rule("", w-2) + "┘")
	return b.String()
}
