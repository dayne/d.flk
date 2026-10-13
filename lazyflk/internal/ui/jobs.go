package ui

import (
	"context"
	"errors"
	"fmt"
	"os/exec"
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"

	"lazyflk/internal/actions"
	"lazyflk/internal/flk"
)

const (
	jobKeep  = 50   // jobs kept in the command log
	jobLines = 5000 // output lines kept per job
)

// job is one action's flk command: running, or finished and kept in the
// command log (SPEC 3.2). It never holds the command's stdin, which may be
// a secret.
type job struct {
	id      int
	title   string // what was done to what: "stop ─ minecraft-flk / mellow"
	args    []string
	line    string // the command as shown
	started time.Time
	ended   time.Time
	lines   []logLine
	stream  *flk.Stream
	err     error
	stopped bool // interrupted by the admin
	back    int  // rows scrolled up from the bottom; 0 follows
	quiet   bool // runs without the job view (a console line); ends in a note
	nowrap  bool // cut long lines (tables) instead of wrapping them
}

func (j *job) running() bool { return j.ended.IsZero() }

type jobStartMsg struct {
	j      *job
	stream *flk.Stream
	err    error
}

type jobChunkMsg struct {
	j     *job
	lines []flk.Line
	done  bool
}

// runJob starts an action's command, shown in the job modal.
func (m *Model) runJob(title string, c actions.Command) tea.Cmd {
	m.jobSeq++
	j := &job{id: m.jobSeq, title: title, args: c.Args, line: c.Line(), started: m.now()}
	m.addJob(j)
	m.shown = j
	client, args, stdin := m.opt.Client, c.Args, c.Stdin
	return func() tea.Msg {
		s, err := client.StreamInput(context.Background(), stdin, args...)
		return jobStartMsg{j, s, err}
	}
}

func (m *Model) addJob(j *job) {
	m.jobs = append(m.jobs, j)
	if len(m.jobs) > jobKeep {
		m.jobs = m.jobs[len(m.jobs)-jobKeep:]
	}
}

func contextBackground() context.Context { return context.Background() }

// classifyJobLine styles a line of an action's output: flk's errors in
// red, its ==> steps and Next: hints in bold.
func classifyJobLine(l flk.Line) logLine {
	ll := classifyLog(l, func(id string) string { return id })
	if ll.kind == logHeader || ll.kind == logBanner {
		ll.kind = logText // only flk logs has those
	}
	switch {
	case l.Stderr && strings.HasPrefix(ll.text, "Error:"):
		ll.kind = logError
	case l.Stderr:
		ll.kind = logText // progress and warnings go to stderr too
	case strings.HasPrefix(ll.text, "==>"), strings.HasPrefix(ll.text, "Next:"):
		ll.kind = logHeader
	}
	return ll
}

func (m *Model) jobStarted(msg jobStartMsg) tea.Cmd {
	j := msg.j
	if msg.err != nil {
		j.err = msg.err
		return m.jobEnded(j)
	}
	j.stream = msg.stream
	if j.stopped { // interrupted before it started
		msg.stream.Interrupt()
	}
	return readLines(msg.stream, func(lines []flk.Line, done bool) tea.Msg { return jobChunkMsg{j, lines, done} })
}

func (m *Model) jobChunk(msg jobChunkMsg) tea.Cmd {
	j := msg.j
	for _, l := range msg.lines {
		j.lines = append(j.lines, classifyJobLine(l))
	}
	if drop := len(j.lines) - jobLines; drop > 0 {
		j.lines = append([]logLine(nil), j.lines[drop:]...)
	}
	if !msg.done {
		return readLines(j.stream, func(lines []flk.Line, done bool) tea.Msg { return jobChunkMsg{j, lines, done} })
	}
	j.err = j.stream.Err()
	return m.jobEnded(j)
}

// jobEnded records the end and reloads everything the action may have changed.
func (m *Model) jobEnded(j *job) tea.Cmd {
	j.ended, j.stream = m.now(), nil
	if j.quiet {
		if m.logs != nil {
			if j.err != nil {
				m.logs.note = "send failed: " + lastError(j)
			} else {
				m.logs.note = "sent: " + j.args[len(j.args)-1]
			}
		}
		return nil
	}
	for _, f := range m.cache {
		f.at = time.Time{}
	}
	if m.quitting && m.runningJob() == nil {
		return tea.Quit
	}
	return m.reload()
}

func (m *Model) runningJob() *job {
	for _, j := range m.jobs {
		if j.running() {
			return j
		}
	}
	return nil
}

func (j *job) interrupt() {
	if !j.running() || j.stopped {
		return
	}
	j.stopped = true
	if j.stream != nil {
		j.stream.Interrupt()
	}
}

// status is the job's state in a few words, styled.
func (j *job) status(now time.Time) string {
	took := func(end time.Time) string { return end.Sub(j.started).Round(time.Second).String() }
	switch {
	case j.running() && j.stopped:
		return styleWarn.Render("interrupting…")
	case j.running():
		return styleWarn.Render("running since " + j.started.Format("15:04:05"))
	case j.stopped:
		return styleWarn.Render("interrupted after " + took(j.ended))
	case j.err != nil:
		return styleBad.Render("✘ failed (" + exitText(j.err) + ") after " + took(j.ended))
	}
	return styleOK.Render("✔ done in " + took(j.ended))
}

func (j *job) icon() string {
	switch {
	case j.running():
		return styleWarn.Render("⟳")
	case j.stopped:
		return styleWarn.Render("■")
	case j.err != nil:
		return styleBad.Render("✘")
	}
	return styleOK.Render("✔")
}

func exitText(err error) string {
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		return fmt.Sprintf("exit %d", ee.ExitCode())
	}
	var fe *flk.Error
	if errors.As(err, &fe) && fe.Err != nil {
		return fe.Err.Error()
	}
	return err.Error()
}

// jobBody is the job's output, wrapped to w, with the command on top.
func (j *job) body(w int) []string {
	var out []string
	for i, l := range wrapKeep("$ "+j.line, w) {
		if i > 0 {
			l = "  " + l
		}
		out = append(out, styleTitle.Render(l))
	}
	out = append(out, "")
	for _, l := range j.lines {
		if j.nowrap {
			out = append(out, logLine{text: ansi.Truncate(l.text, w, "…"), kind: l.kind}.styled())
			continue
		}
		for _, r := range wrapKeep(l.text, w) {
			out = append(out, logLine{text: r, kind: l.kind}.styled())
		}
	}
	if !j.running() && j.err != nil && len(j.lines) == 0 {
		for _, l := range wrap(j.err.Error(), w) {
			out = append(out, styleBad.Render(l))
		}
	}
	if j.running() && len(j.lines) == 0 {
		out = append(out, styleDim.Render("waiting for output…"))
	}
	return out
}

// jobScreen is the running (or finished) job, full screen.
func (m *Model) jobScreen(j *job) string {
	w, h := m.width, m.height
	body := j.body(w - 4)
	room := h - 4
	j.back = max(min(j.back, len(body)-room), 0)
	end := len(body) - j.back
	start := max(end-room, 0)
	shown := append([]string(nil), body[start:end]...)
	for len(shown) < room {
		shown = append(shown, "")
	}
	if start > 0 && j.back > 0 {
		shown[0] = styleDim.Render(fmt.Sprintf("… %d lines above", start))
	}
	var keys string
	if j.running() {
		keys = keyHints("ctrl+c", "interrupt", "esc", "hide (it keeps running)", "↑↓ pgup/dn", "scroll", "y", "copy command")
	} else {
		keys = keyHints("esc", "close", "↑↓ pgup/dn", "scroll", "w", "wrap", "y", "copy command", "L", "command log")
	}
	if m.note != "" {
		keys = m.note
	}
	return strings.Join(box(j.title+" ─ "+j.status(m.now()), shown, keys, w), "\n")
}

// jobKey handles keys while the job modal is shown.
func (m *Model) jobKey(k string) tea.Cmd {
	j := m.shown
	page := max(m.height-8, 1)
	switch k {
	case "ctrl+c":
		if j.running() {
			j.interrupt()
			return nil
		}
		m.shown = nil
	case "esc", "q", "enter":
		m.shown = nil
	case "up", "k":
		j.back++
	case "down", "j":
		j.back = max(j.back-1, 0)
	case "pgup", "ctrl+u":
		j.back += page
	case "pgdown", "ctrl+d", "space":
		j.back = max(j.back-page, 0)
	case "g":
		j.back = 1 << 30
	case "G":
		j.back = 0
	case "w":
		j.nowrap = !j.nowrap
	case "y":
		return m.copy(j.line)
	case "L":
		m.shown = nil
		m.cmdlog = &cmdlogView{}
	}
	return nil
}

// cmdlogView is the command log: every action run this session.
type cmdlogView struct {
	cursor int // index from the newest
}

func (m *Model) cmdlogLines(w, h int) []string {
	var out []string
	if len(m.jobs) == 0 {
		out = append(out, styleDim.Render("nothing run yet: actions (enter or x on a selection) show up here"))
	}
	v := m.cmdlog
	v.cursor = max(min(v.cursor, len(m.jobs)-1), 0)
	for i := range m.jobs {
		j := m.jobs[len(m.jobs)-1-i]
		s := fmt.Sprintf("%s %s  %s", j.icon(), j.started.Format("15:04:05"), j.line)
		if i == v.cursor {
			s = styleSelected.Render(fit(ansi.Strip(s), w))
		}
		out = append(out, s)
	}
	if len(out) > h {
		top := max(min(v.cursor-h/2, len(out)-h), 0)
		out = out[top : top+h]
	}
	return out
}

func (m *Model) cmdlogScreen() string {
	w, h := m.width, m.height
	body := m.cmdlogLines(w-4, h-4)
	for len(body) < h-4 {
		body = append(body, "")
	}
	keys := keyHints("↑↓", "move", "enter", "output", "y", "copy command", "esc", "back")
	return strings.Join(box("Command log ─ what lazyflk ran this session", body, keys, w), "\n")
}

func (m *Model) cmdlogKey(k string) tea.Cmd {
	v := m.cmdlog
	switch k {
	case "esc", "q", "L":
		m.cmdlog = nil
	case "up", "k":
		v.cursor = max(v.cursor-1, 0)
	case "down", "j":
		v.cursor = min(v.cursor+1, max(len(m.jobs)-1, 0))
	case "enter":
		if len(m.jobs) > 0 {
			m.shown = m.jobs[len(m.jobs)-1-v.cursor]
		}
	case "y":
		if len(m.jobs) > 0 {
			return m.copy(m.jobs[len(m.jobs)-1-v.cursor].line)
		}
	}
	return nil
}

// copy puts text on the clipboard through the terminal (OSC 52, which
// works over SSH where the terminal supports it) and says so.
func (m *Model) copy(text string) tea.Cmd {
	m.note = "copied (if your terminal allows OSC 52): " + text
	return tea.SetClipboard(text)
}
