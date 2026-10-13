// Package providers shows what else the admin looks after on a flk host
// (SPEC 10): storage, podman, pinned systemd services, and each app's own
// actions. Like flk, each uses its tool's CLI, shows every command, and
// never runs anything as root: root steps are copied, not run.
package providers

import (
	"context"
	"fmt"
	"io/fs"
	"strings"

	"lazyflk/internal/actions"
	"lazyflk/internal/flk"
)

// Host gives the runner for a program on this host (podman, systemctl,
// lsblk, df, journalctl...); the real one execs it, the demo one serves
// fixtures.
type Host func(prog string) flk.Runner

// State is an item's health, shown as its icon.
type State int

const (
	OK State = iota
	Warn
	Bad
	Off // stopped, not installed: neither good nor bad
)

// Item is one thing a provider shows: a tree line, its detail, what's
// wrong with it, and what can be done.
type Item struct {
	Key      string // stable across refreshes
	Label    string // the tree line
	State    State
	Title    string   // the detail pane's title
	Lines    []string // the detail, plain text
	Problems []string // for Needs attention
	Fix      *actions.Action
	Actions  []actions.Action
	Logs     *actions.Command // followed with l
}

// Env is what providers need from flk: where its data lives.
type Env struct {
	StateDir  string
	MountDirs []string
	BackupDir string // from flk disk; "" when not set
}

// Provider is one section of the tree below Host.
type Provider interface {
	Name() string    // the section heading
	Command() string // what it runs, shown above the detail
	Load(ctx context.Context, h Host, env Env) ([]Item, error)
}

// All is the providers in SPEC 10's order (app actions live in the app's
// own menu, not here).
func All() []Provider { return []Provider{Storage{}, Podman{}, Services{}} }

func run(ctx context.Context, h Host, prog string, args ...string) ([]byte, error) {
	return h(prog).Run(ctx, args...)
}

// field lays out "label  value" as the flk detail panes do.
func field(label, value string) string { return fmt.Sprintf("%-9s %s", label, value) }

// Fake serves captured host output for --demo and tests: Files maps a
// command line ("podman images --format json") to a fixture file. A
// command with no fixture fails, and an action says demo mode ran nothing.
type Fake struct {
	FS    fs.FS
	Files map[string]string
}

// DemoFiles are the fixtures/ files for the host commands lazyflk runs
// (see fixtures/README.md).
var DemoFiles = map[string]string{
	"podman ps -a --external --format json": "podman-ps.json",
	"podman images --format json":           "podman-images.json",
	"lsblk -e7 -b --json -o " + lsblkCols:   "lsblk.json",
	"systemctl show --timestamp=utc -p " + unitProps + " " + strings.Join(append(flkUnits, DefaultPins...), " "): "systemctl-show.txt",
	"id -Gn":            "id-groups.txt",
	"buildah --version": "buildah-version.txt",
}

func (f *Fake) For(prog string) flk.Runner { return fakeProg{f, prog} }

type fakeProg struct {
	f    *Fake
	prog string
}

func (p fakeProg) lookup(args []string) ([]byte, bool) {
	key := strings.Join(append([]string{p.prog}, args...), " ")
	name, ok := p.f.Files[key]
	if !ok && p.prog == "df" {
		name, ok = "df.txt", true // df over the demo's mount dirs
	}
	if !ok && p.prog == "journalctl" && len(args) > 1 && args[0] == "-u" {
		name, ok = "journal-"+strings.TrimSuffix(args[1], ".service")+".txt", true
	}
	if !ok {
		return nil, false
	}
	b, err := fs.ReadFile(p.f.FS, name)
	return b, err == nil
}

func (p fakeProg) Run(ctx context.Context, args ...string) ([]byte, error) {
	if b, ok := p.lookup(args); ok {
		return b, nil
	}
	return nil, &flk.Error{Args: args, Stderr: "Error: demo mode has no captured output for: " + flk.CommandLineFor(p.prog, args...)}
}

func (p fakeProg) Stream(ctx context.Context, stdin string, args ...string) (*flk.Stream, error) {
	if b, ok := p.lookup(args); ok {
		return flk.TextStream(ctx, string(b), hasAny(args, "-f", "--follow")), nil
	}
	return flk.TextStream(ctx, "demo mode: "+p.prog+" was not run\n", false), nil
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
