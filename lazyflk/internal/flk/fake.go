package flk

import (
	"context"
	"encoding/json"
	"fmt"
	"io/fs"
	"strings"
	"sync"
)

// Fake is a Runner that answers from captured flk output (fixtures/, see
// its README for which command made which file) and records every call. A
// command with no fixture fails the way flk does, with an "Error:" message.
type Fake struct {
	FS fs.FS
	// Fail, if set, decides whether an action (a streamed command with no
	// fixture) fails, and how.
	Fail func(args []string) error

	mu     sync.Mutex
	calls  [][]string
	stdins []string
}

func NewFake(fsys fs.FS) *Fake { return &Fake{FS: fsys} }

// Calls returns the argv of every command run so far.
func (f *Fake) Calls() [][]string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([][]string(nil), f.calls...)
}

// Stdins returns the stdin given to each streamed command so far.
func (f *Fake) Stdins() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.stdins...)
}

func (f *Fake) record(args []string) {
	f.mu.Lock()
	f.calls = append(f.calls, append([]string(nil), args...))
	f.mu.Unlock()
}

func (f *Fake) missing(args []string) error {
	return &Error{Args: args, Err: fs.ErrNotExist,
		Stderr: fmt.Sprintf("Error: demo mode has no captured output for: %s", CommandLine(args...))}
}

func (f *Fake) Run(ctx context.Context, args ...string) ([]byte, error) {
	f.record(args)
	if err := ctx.Err(); err != nil {
		return nil, &Error{Args: args, Err: err}
	}
	if name, ok := fixtureFor(args); ok {
		out, err := fs.ReadFile(f.FS, name)
		if err == nil && (name != "machine-status.json" || recordMatches(out, args[len(args)-1])) {
			return out, nil
		}
	}
	return nil, f.missing(args)
}

// fixtureFor maps a command line to its fixture file name.
func fixtureFor(args []string) (string, bool) {
	app := ""
	if len(args) >= 2 && (args[0] == "-a" || args[0] == "--app") {
		app, args = args[1], args[2:]
	}
	cmd := strings.Join(args, " ")
	if len(args) > 0 && args[0] == "events" {
		return "events.txt", true
	}
	if app == "" && len(args) == 2 && args[0] == "help" && !strings.HasPrefix(args[1], "-") {
		return "help-" + args[1] + ".txt", true
	}
	if app == "" {
		name, ok := map[string]string{
			"context":                        "context.txt",
			"context --all":                  "context-all.txt",
			"context --all --json":           "context-all.json",
			"context --all --json --no-host": "context-all-nohost.json",
			"machine stats --all --json":     "machine-stats.json",
			"disk --json":                    "disk.json",
			"images --json":                  "images.json",
			"help --all --json":              "help-all.json",
			"doctor --json":                  "doctor.json",
			"apps list --json":               "apps-list.json",
			"ports list --json":              "ports-list.json",
		}[cmd]
		return name, ok
	}
	switch {
	case cmd == "context --json":
		return "context-" + app + ".json", true
	case cmd == "status --json":
		return "status-" + app + ".json", true
	case cmd == "releases --json":
		return "releases-" + app + ".json", true
	case cmd == "volumes list --json":
		return "volumes-" + app + ".json", true
	case cmd == "secrets list --json":
		return "secrets-" + app + ".json", true
	case cmd == "volumes backups --json":
		return "backups-" + app + ".json", true
	case cmd == "config show", cmd == "config show --json":
		return "config-" + app + ".json", true
	case len(args) >= 3 && args[0] == "files" && (args[1] == "ls" || args[1] == "cat"):
		// files-ls-PATH.json / files-cat-PATH.txt, PATH with / as -
		_, p, _ := strings.Cut(args[2], ":")
		p = strings.ReplaceAll(strings.Trim(p, "/"), "/", "-")
		if p == "" {
			p = "root"
		}
		if args[1] == "ls" {
			return "files-ls-" + p + ".json", true
		}
		return "files-cat-" + p + ".txt", true
	case len(args) == 3 && args[0] == "machine" && args[1] == "status":
		return "machine-status.json", true
	case len(args) > 0 && args[0] == "logs" && !hasAny(args, "-f", "--follow"):
		return "logs-" + app + ".txt", true
	}
	return "", false
}

// recordMatches reports whether a machine record answers to ref, which flk
// accepts as an ID prefix or the machine name.
func recordMatches(out []byte, ref string) bool {
	var r MachineRecord
	if json.Unmarshal(out, &r) != nil || ref == "" {
		return false
	}
	return strings.HasPrefix(r.ID, ref) || r.Name == ref
}

func hasAny(args []string, opts ...string) bool {
	for _, a := range args {
		for _, o := range opts {
			if a == o {
				return true
			}
		}
	}
	return false
}
