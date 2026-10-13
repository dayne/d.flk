package flk

import (
	"bytes"
	"context"
	"io/fs"
	"os"
	"os/exec"
	"strings"
	"sync"
	"syscall"
	"time"
)

// Line is one line of a streamed command's output.
type Line struct {
	Text   string
	Stderr bool
}

// Stream is a running command whose output arrives line by line on Lines,
// which closes when the command ends.
type Stream struct {
	Lines <-chan Line

	interrupt func()
	gone      chan struct{} // closed by Stop: drop further output
	stopOnce  sync.Once
	mu        sync.Mutex
	err       error
}

// Err is why the command ended (nil for a clean exit or Stop); valid once
// Lines is closed.
func (s *Stream) Err() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.err
}

func (s *Stream) setErr(err error) {
	s.mu.Lock()
	s.err = err
	s.mu.Unlock()
}

// Interrupt asks the command to stop, like Ctrl-C in a terminal. Keep
// reading Lines to see how it ends.
func (s *Stream) Interrupt() { s.interrupt() }

// Stop interrupts the command and drops the rest of its output.
func (s *Stream) Stop() {
	s.stopOnce.Do(func() { close(s.gone) })
	s.interrupt()
}

func newStream() (*Stream, chan Line) {
	ch := make(chan Line, 256)
	return &Stream{Lines: ch, gone: make(chan struct{}), interrupt: func() {}}, ch
}

// send delivers a line unless the reader has gone.
func (s *Stream) send(ch chan Line, l Line) {
	select {
	case ch <- l:
	case <-s.gone:
	}
}

// Stream starts a long-running flk command such as `logs -f`. It has no
// timeout: the caller stops it.
func (c *Client) Stream(ctx context.Context, args ...string) (*Stream, error) {
	return c.Runner.Stream(ctx, "", args...)
}

// StreamInput is Stream with stdin, which is how secret values reach flk
// (`secrets set NAME=-`) without showing up in the command line.
func (c *Client) StreamInput(ctx context.Context, stdin string, args ...string) (*Stream, error) {
	return c.Runner.Stream(ctx, stdin, args...)
}

// killAfter is how long an interrupted command gets to clean up before
// it's killed.
const killAfter = 10 * time.Second

// command builds a flk process in its own process group, so an interrupt
// reaches everything it started (as Ctrl-C would) and nothing else.
func (x Exec) command(stdin string, args []string) *exec.Cmd {
	cmd := exec.Command(x.Path, args...)
	cmd.Env = append(os.Environ(), "NO_COLOR=1")
	if stdin != "" {
		cmd.Stdin = strings.NewReader(stdin)
	}
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.WaitDelay = time.Second // don't wait on children that keep stdout open
	return cmd
}

// watch sends SIGINT to cmd's process group when interrupted or when ctx
// ends, then SIGKILL if it's still running after killAfter. It returns
// the interrupt func and a func to call once the command has exited.
func watch(ctx context.Context, cmd *exec.Cmd) (interrupt func(), exited func()) {
	done := make(chan struct{})
	ask := make(chan struct{})
	var once sync.Once
	interrupt = func() { once.Do(func() { close(ask) }) }
	go func() {
		select {
		case <-done:
			return
		case <-ctx.Done():
		case <-ask:
		}
		pg := -cmd.Process.Pid
		syscall.Kill(pg, syscall.SIGINT)
		select {
		case <-done:
		case <-time.After(killAfter):
			syscall.Kill(pg, syscall.SIGKILL)
		}
	}()
	return interrupt, func() { close(done) }
}

func (x Exec) Run(ctx context.Context, args ...string) ([]byte, error) {
	cmd := x.command("", args)
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	if err := cmd.Start(); err != nil {
		return nil, &Error{Args: args, Err: err}
	}
	_, exited := watch(ctx, cmd)
	err := cmd.Wait()
	exited()
	if err != nil {
		if ctx.Err() != nil {
			err = &timeoutError{ctx.Err()}
		}
		return out.Bytes(), &Error{Args: args, Stderr: errb.String(), Err: err}
	}
	return out.Bytes(), nil
}

type timeoutError struct{ err error }

func (e *timeoutError) Error() string { return "timed out: " + e.err.Error() }
func (e *timeoutError) Unwrap() error { return e.err }

// lineWriter turns writes into Lines.
type lineWriter struct {
	s      *Stream
	ch     chan Line
	stderr bool
	buf    []byte
	all    *strings.Builder // stderr kept for the error
}

func (w *lineWriter) Write(p []byte) (int, error) {
	w.buf = append(w.buf, p...)
	for {
		i := bytes.IndexByte(w.buf, '\n')
		if i < 0 {
			break
		}
		w.emit(string(w.buf[:i]))
		w.buf = w.buf[i+1:]
	}
	if len(w.buf) > 1<<20 { // a megabyte without a newline: pass it on
		w.flush()
	}
	return len(p), nil
}

func (w *lineWriter) emit(s string) {
	if w.all != nil {
		w.all.WriteString(s + "\n")
	}
	w.s.send(w.ch, Line{Text: s, Stderr: w.stderr})
}

func (w *lineWriter) flush() {
	if len(w.buf) > 0 {
		w.emit(string(w.buf))
		w.buf = nil
	}
}

func (x Exec) Stream(ctx context.Context, stdin string, args ...string) (*Stream, error) {
	s, ch := newStream()
	cmd := x.command(stdin, args)
	var errText strings.Builder
	out := &lineWriter{s: s, ch: ch}
	errw := &lineWriter{s: s, ch: ch, stderr: true, all: &errText}
	cmd.Stdout, cmd.Stderr = out, errw
	if err := cmd.Start(); err != nil {
		return nil, &Error{Args: args, Err: err}
	}
	interrupt, exited := watch(ctx, cmd)
	s.interrupt = interrupt
	go func() {
		err := cmd.Wait()
		exited()
		out.flush()
		errw.flush()
		select {
		case <-s.gone:
		default:
			if err != nil {
				s.setErr(&Error{Args: args, Stderr: errText.String(), Err: err})
			}
		}
		close(ch)
	}()
	return s, nil
}

// Stream serves a fixture line by line; with -f/--follow it then waits,
// like `tail -F` on a quiet log, until stopped. A command with no fixture
// is an action: demo mode says so and runs nothing.
func (f *Fake) Stream(ctx context.Context, stdin string, args ...string) (*Stream, error) {
	f.record(args)
	f.mu.Lock()
	f.stdins = append(f.stdins, stdin)
	f.mu.Unlock()
	follow := hasAny(args, "-f", "--follow")
	var plain []string
	for _, a := range args {
		if a != "-f" && a != "--follow" {
			plain = append(plain, a)
		}
	}
	var out []byte
	if name, ok := fixtureFor(plain); ok {
		var err error
		if out, err = fs.ReadFile(f.FS, name); err != nil {
			return nil, f.missing(args)
		}
	} else {
		if f.Fail != nil {
			if err := f.Fail(args); err != nil {
				return nil, err
			}
		}
		out = []byte("demo mode: flk was not run\n")
	}
	s, ch := newStream()
	stop := make(chan struct{})
	var once sync.Once
	s.interrupt = func() { once.Do(func() { close(stop) }) }
	go func() {
		defer close(ch)
		for _, l := range strings.SplitAfter(string(out), "\n") {
			if l == "" {
				continue
			}
			select {
			case ch <- Line{Text: strings.TrimSuffix(l, "\n")}:
			case <-s.gone:
				return
			case <-stop:
				return
			case <-ctx.Done():
				return
			}
		}
		if follow {
			select {
			case <-stop:
			case <-ctx.Done():
			}
		}
	}()
	return s, nil
}
