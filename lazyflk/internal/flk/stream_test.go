package flk

import (
	"context"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

// collect reads up to n lines, or until the stream ends.
func collect(t *testing.T, s *Stream, n int) []Line {
	t.Helper()
	var got []Line
	timeout := time.After(5 * time.Second)
	for len(got) < n {
		select {
		case l, ok := <-s.Lines:
			if !ok {
				return got
			}
			got = append(got, l)
		case <-timeout:
			t.Fatalf("only %d lines", len(got))
		}
	}
	return got
}

func TestFakeStream(t *testing.T) {
	c, f := fakeClient()
	ctx := context.Background()
	s, err := c.Stream(ctx, "-a", "minecraft-flk", "logs", "-n", "40", "--no-tail")
	if err != nil {
		t.Fatal(err)
	}
	lines := collect(t, s, 1000)
	if len(lines) != 40 || !strings.Contains(lines[0].Text, "Loading Geyser") || s.Err() != nil {
		t.Errorf("%d lines, first %q, err %v", len(lines), lines[0].Text, s.Err())
	}

	// follow serves the fixture, then waits like tail -F until stopped
	s, err = c.Stream(ctx, "-a", "minecraft-flk", "logs", "-i", "225d58f615e7e6", "-n", "40", "-f")
	if err != nil {
		t.Fatal(err)
	}
	collect(t, s, 40)
	select {
	case l, ok := <-s.Lines:
		t.Fatalf("follow ended early: %q %v", l.Text, ok)
	case <-time.After(50 * time.Millisecond):
	}
	s.Stop()
	if _, ok := <-s.Lines; ok {
		t.Error("Stop should close Lines")
	}
	if _, err := c.Stream(ctx, "-a", "flkt-nope", "logs", "-f"); err == nil {
		t.Error("no fixture should fail")
	}
	if n := len(f.Calls()); n != 3 {
		t.Errorf("%d calls recorded", n)
	}
}

func TestExecStream(t *testing.T) {
	script := filepath.Join(t.TempDir(), "flk")
	os.WriteFile(script, []byte(`#!/bin/sh
echo one; echo "tail: oops" >&2; echo two
[ "$1" = fail ] && { echo "Error: no logs yet" >&2; exit 1; }
[ "$1" = follow ] && exec sleep 10
exit 0
`), 0o755)
	c := New(Exec{Path: script})
	ctx := context.Background()

	s, err := c.Stream(ctx, "ok")
	if err != nil {
		t.Fatal(err)
	}
	var out, errs []string
	for _, l := range collect(t, s, 10) {
		if l.Stderr {
			errs = append(errs, l.Text)
		} else {
			out = append(out, l.Text)
		}
	}
	if !reflect.DeepEqual(out, []string{"one", "two"}) || !reflect.DeepEqual(errs, []string{"tail: oops"}) || s.Err() != nil {
		t.Errorf("out %v, err lines %v, err %v", out, errs, s.Err())
	}

	s, _ = c.Stream(ctx, "fail")
	collect(t, s, 10)
	if s.Err() == nil || !strings.Contains(s.Err().Error(), "Error: no logs yet") {
		t.Errorf("fail: %v", s.Err())
	}

	s, _ = c.Stream(ctx, "follow")
	collect(t, s, 3)
	start := time.Now()
	s.Stop()
	for range s.Lines {
	}
	if s.Err() != nil || time.Since(start) > 3*time.Second {
		t.Errorf("stop: %v after %v", s.Err(), time.Since(start))
	}
}

// Actions get stdin; Interrupt is Ctrl-C for the whole process group, and
// what the command prints while it cleans up still arrives.
func TestExecInterrupt(t *testing.T) {
	dir := t.TempDir()
	script := filepath.Join(dir, "flk")
	os.WriteFile(script, []byte(`#!/bin/sh
read secret
echo "got $secret"
trap 'echo "cleaning up"; exit 130' INT
sh -c 'trap "echo child stopped; exit 0" INT; echo ready; while :; do sleep 0.05; done'
`), 0o755)
	c := New(Exec{Path: script})
	s, err := c.StreamInput(context.Background(), "hunter2\n", "deploy")
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for l := range s.Lines {
		got = append(got, l.Text)
		if l.Text == "ready" {
			s.Interrupt()
		}
	}
	want := []string{"got hunter2", "ready", "child stopped", "cleaning up"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %q", got)
	}
	if s.Err() == nil || !strings.Contains(s.Err().Error(), "exit status 130") {
		t.Errorf("err %v", s.Err())
	}
}

func TestExecRunTimeout(t *testing.T) {
	script := filepath.Join(t.TempDir(), "flk")
	os.WriteFile(script, []byte("#!/bin/sh\nexec sleep 10\n"), 0o755)
	c := New(Exec{Path: script})
	c.Timeout = 100 * time.Millisecond
	start := time.Now()
	_, err := c.Run(context.Background(), "context")
	if err == nil || !strings.Contains(err.Error(), "timed out") || time.Since(start) > 3*time.Second {
		t.Errorf("%v after %v", err, time.Since(start))
	}
}

// In demo mode an action prints a note and runs nothing.
func TestFakeAction(t *testing.T) {
	c, f := fakeClient()
	s, err := c.StreamInput(context.Background(), "v", "-a", "flkt-x", "secrets", "set", "K=-")
	if err != nil {
		t.Fatal(err)
	}
	if l := collect(t, s, 10); len(l) != 1 || !strings.Contains(l[0].Text, "demo mode") {
		t.Errorf("got %v", l)
	}
	if st := f.Stdins(); len(st) != 1 || st[0] != "v" {
		t.Errorf("stdins %q", st)
	}
	f.Fail = func(args []string) error { return &Error{Args: args, Stderr: "Error: nope"} }
	if _, err := c.Stream(context.Background(), "ports", "sync"); err == nil {
		t.Error("Fail should fail it")
	}
}
