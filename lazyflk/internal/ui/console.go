package ui

import (
	"os"
	"strings"
	"sync"

	tea "charm.land/bubbletea/v2"

	"lazyflk/internal/actions"
	"lazyflk/internal/flk"
)

// attachView explains the console before handing over the terminal
// (SPEC 5.3): how to get back, and that it isn't a shell.
type attachView struct {
	title string
	args  []string
}

type attachDoneMsg struct {
	j      *job
	err    error
	stderr *tailBuffer
}

// tailBuffer keeps the end of what flk writes to stderr while it has the
// terminal, to show why an attach failed once lazyflk is back.
type tailBuffer struct {
	mu  sync.Mutex
	buf []byte
}

func (t *tailBuffer) Write(p []byte) (int, error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.buf = append(t.buf, p...)
	if len(t.buf) > 4096 {
		t.buf = t.buf[len(t.buf)-4096:]
	}
	return len(p), nil
}

func (t *tailBuffer) String() string {
	t.mu.Lock()
	defer t.mu.Unlock()
	return string(t.buf)
}

// consoleMachine is the machine c and > act on: the selected one, or the
// selected app's only machine.
func (m *Model) consoleMachine() (flk.App, flk.Machine, bool) {
	n, ok := m.selected()
	if !ok || n.kind < kindApp || n.kind > kindPorts {
		return flk.App{}, flk.Machine{}, false
	}
	a := m.apps[n.app]
	switch {
	case n.kind == kindMachine:
		return a, a.Machines[n.machine], true
	case len(a.Machines) == 1:
		return a, a.Machines[0], true
	}
	return a, flk.Machine{}, false
}

func (m *Model) openAttach() tea.Cmd {
	if m.opt.ReadOnly {
		m.note = "read-only: the console is off (it types into the app)"
		return nil
	}
	a, mc, ok := m.consoleMachine()
	switch {
	case !ok && a.Name != "":
		m.note = "the console is per machine: select one"
		return nil
	case !ok:
		return nil
	case !mc.Started():
		m.note = "console: " + or(mc.Name, mc.ID) + " isn't running"
		return nil
	}
	m.attach = &attachView{title: "console ─ " + a.Name + " / " + or(mc.Name, mc.ID),
		args: []string{"-a", a.Name, "console", mc.ID}}
	return nil
}

func (m *Model) attachBox() []string {
	w := min(m.width-4, 84)
	inner := w - 4
	body := []string{styleTitle.Render("$ " + flk.CommandLine(m.attach.args...)), ""}
	detach := "Ctrl-b d"
	if os.Getenv("TMUX") != "" {
		detach = "Ctrl-b Ctrl-b d (you're inside tmux: the first Ctrl-b goes to yours)"
	}
	for _, p := range []string{
		"This hands the terminal to the machine's serial console: you see the app's output, and what you type goes to its stdin. It isn't a shell, and Ctrl-C there doesn't stop the app (use stop).",
		"",
		"To come back to lazyflk, detach: " + detach + ".",
	} {
		body = append(body, wrap(p, inner)...)
	}
	return box(m.attach.title, body, keyHints("enter", "attach", "esc", "cancel"), w)
}

func (m *Model) attachKey(k string) tea.Cmd {
	at := m.attach
	switch k {
	case "esc", "q", "n":
		m.attach = nil
	case "enter", "y":
		m.attach = nil
		return m.runAttach(at)
	}
	return nil
}

// runAttach suspends the UI and runs the console in the real terminal; it
// goes in the command log like any action.
func (m *Model) runAttach(at *attachView) tea.Cmd {
	r, ok := m.opt.Client.Runner.(flk.Interactiver)
	if !ok || m.opt.Demo {
		m.note = "demo mode: would run " + flk.CommandLine(at.args...)
		return nil
	}
	m.jobSeq++
	j := &job{id: m.jobSeq, title: at.title, args: at.args, line: flk.CommandLine(at.args...), started: m.now()}
	m.addJob(j)
	cmd := r.Interactive(at.args...)
	tail := &tailBuffer{}
	cmd.Stdin, cmd.Stdout = os.Stdin, os.Stdout
	cmd.Stderr = teeWriter{os.Stderr, tail}
	return tea.ExecProcess(cmd, func(err error) tea.Msg { return attachDoneMsg{j, err, tail} })
}

type teeWriter struct {
	a, b interface{ Write([]byte) (int, error) }
}

func (t teeWriter) Write(p []byte) (int, error) {
	t.b.Write(p)
	return t.a.Write(p)
}

func (m *Model) attachDone(msg attachDoneMsg) tea.Cmd {
	j := msg.j
	j.lines = append(j.lines, logLine{text: "(the console had the terminal)", kind: logText})
	for _, l := range strings.Split(strings.TrimSpace(msg.stderr.String()), "\n") {
		if l != "" {
			j.lines = append(j.lines, classifyJobLine(flk.Line{Text: l, Stderr: true}))
		}
	}
	if msg.err != nil {
		j.err = msg.err
		m.note = "console: " + lastError(j)
	}
	return m.jobEnded(j)
}

// sendLine types one line into a machine's console without attaching
// (flk console ID --send, gap G3). It runs in the background; the answer
// shows up in the log being followed.
func (m *Model) sendLine(msg sendLineMsg) tea.Cmd {
	c := actions.Command{Args: []string{"-a", msg.app, "console", msg.id, "--send", msg.text}}
	m.jobSeq++
	j := &job{id: m.jobSeq, title: "send ─ " + msg.app, args: c.Args, line: c.Line(), started: m.now(), quiet: true}
	m.addJob(j)
	client := m.opt.Client
	return func() tea.Msg {
		s, err := client.StreamInput(contextBackground(), "", c.Args...)
		return jobStartMsg{j, s, err}
	}
}

// lastError is the job's most telling failure line.
func lastError(j *job) string {
	for i := len(j.lines) - 1; i >= 0; i-- {
		if j.lines[i].kind == logError {
			return j.lines[i].text
		}
	}
	if j.err != nil {
		return exitText(j.err)
	}
	return ""
}
