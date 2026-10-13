package flk

import (
	"bufio"
	"context"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"
)

// Line is one line of a streamed command's output.
type Line struct {
	Text   string
	Stderr bool
}

// Stream is a running command whose output arrives line by line on Lines,
// which closes when the command ends. Stop ends it early.
type Stream struct {
	Lines <-chan Line
	stop  context.CancelFunc
	mu    sync.Mutex
	err   error
}

// Err is why the command ended (nil for a clean exit or Stop); valid once
// Lines is closed.
func (s *Stream) Err() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.err
}

func (s *Stream) Stop() { s.stop() }

// Stream starts a long-running flk command such as `logs -f`. It has no
// timeout: the caller stops it.
func (c *Client) Stream(ctx context.Context, args ...string) (*Stream, error) {
	return c.Runner.Stream(ctx, args...)
}

func newStream(ctx context.Context) (*Stream, chan Line, context.Context) {
	ctx, cancel := context.WithCancel(ctx)
	ch := make(chan Line, 256)
	return &Stream{Lines: ch, stop: cancel}, ch, ctx
}

func (x Exec) Stream(ctx context.Context, args ...string) (*Stream, error) {
	s, ch, ctx := newStream(ctx)
	cmd := exec.CommandContext(ctx, x.Path, args...)
	cmd.Env = append(os.Environ(), "NO_COLOR=1")
	cmd.WaitDelay = time.Second
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		s.stop()
		return nil, err
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		s.stop()
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		s.stop()
		return nil, &Error{Args: args, Err: err}
	}
	var wg sync.WaitGroup
	var errText strings.Builder
	pump := func(r io.Reader, isErr bool) {
		defer wg.Done()
		sc := bufio.NewScanner(r)
		sc.Buffer(make([]byte, 64*1024), 1024*1024)
		for sc.Scan() {
			if isErr {
				errText.WriteString(sc.Text() + "\n")
			}
			select {
			case ch <- Line{Text: sc.Text(), Stderr: isErr}:
			case <-ctx.Done():
			}
		}
	}
	wg.Add(2)
	go pump(stdout, false)
	go pump(stderr, true)
	go func() {
		wg.Wait()
		err := cmd.Wait()
		s.mu.Lock()
		if err != nil && ctx.Err() == nil {
			s.err = &Error{Args: args, Stderr: errText.String(), Err: err}
		}
		s.mu.Unlock()
		s.stop()
		close(ch)
	}()
	return s, nil
}

// Stream serves a fixture line by line; with -f/--follow it then waits,
// like `tail -F` on a quiet log, until stopped.
func (f *Fake) Stream(ctx context.Context, args ...string) (*Stream, error) {
	f.record(args)
	follow := hasAny(args, "-f", "--follow")
	var plain []string
	for _, a := range args {
		if a != "-f" && a != "--follow" {
			plain = append(plain, a)
		}
	}
	name, ok := fixtureFor(plain)
	var out []byte
	var err error
	if ok {
		out, err = fs.ReadFile(f.FS, name)
	}
	if !ok || err != nil {
		return nil, f.missing(args)
	}
	s, ch, ctx := newStream(ctx)
	go func() {
		defer close(ch)
		defer s.stop()
		for _, l := range strings.SplitAfter(string(out), "\n") {
			if l == "" {
				continue
			}
			select {
			case ch <- Line{Text: strings.TrimSuffix(l, "\n")}:
			case <-ctx.Done():
				return
			}
		}
		if follow {
			<-ctx.Done()
		}
	}()
	return s, nil
}
