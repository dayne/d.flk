// Package flk talks to flk through its CLI, the only interface lazyflk uses
// (SPEC 3.1). A Runner executes one flk command; Client turns commands into
// typed results. Exec runs the real binary, Fake serves fixtures.
package flk

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

// Runner runs `flk ARGS...`: Run waits and returns stdout, Stream returns
// output as it comes (stdin, if not empty, is the command's input).
type Runner interface {
	Run(ctx context.Context, args ...string) ([]byte, error)
	Stream(ctx context.Context, stdin string, args ...string) (*Stream, error)
}

// Error is a failed flk command. Stderr starts with "Error:" and usually
// ends with the fix, so show it as is.
type Error struct {
	Args   []string
	Stderr string
	Err    error
}

func (e *Error) Error() string {
	if s := strings.TrimSpace(e.Stderr); s != "" {
		return s
	}
	return fmt.Sprintf("flk %s: %v", strings.Join(e.Args, " "), e.Err)
}

func (e *Error) Unwrap() error { return e.Err }

// Exec runs the real flk binary.
type Exec struct {
	Path string
}

// FindFlk resolves the flk binary: the given path, then $LAZYFLK_FLK, then PATH.
func FindFlk(path string) (string, error) {
	if path == "" {
		path = os.Getenv("LAZYFLK_FLK")
	}
	if path == "" {
		path = "flk"
	}
	p, err := exec.LookPath(path)
	if err != nil {
		return "", fmt.Errorf("can't find flk (%s): pass --flk PATH or set LAZYFLK_FLK", path)
	}
	return p, nil
}

// Client runs flk commands with a timeout and decodes their output.
type Client struct {
	Runner  Runner
	Timeout time.Duration
}

// DefaultTimeout bounds every flk call; a deploy can hold flk's lock for
// seconds (SPEC gap G1), so this is generous.
const DefaultTimeout = 30 * time.Second

func New(r Runner) *Client { return &Client{Runner: r, Timeout: DefaultTimeout} }

// Run runs one flk command under the client's timeout.
func (c *Client) Run(ctx context.Context, args ...string) ([]byte, error) {
	if c.Timeout > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, c.Timeout)
		defer cancel()
	}
	return c.Runner.Run(ctx, args...)
}

func decode[T any](c *Client, ctx context.Context, args ...string) (T, error) {
	var v T
	out, err := c.Run(ctx, args...)
	if err != nil {
		return v, err
	}
	if err := json.Unmarshal(out, &v); err != nil {
		return v, &Error{Args: args, Err: fmt.Errorf("bad JSON: %w", err)}
	}
	return v, nil
}

// CommandLine renders args the way the admin would type them.
func CommandLine(args ...string) string { return CommandLineFor("flk", args...) }

// CommandLineFor renders another program's command line (podman,
// systemctl...) the same way.
func CommandLineFor(prog string, args ...string) string {
	parts := []string{prog}
	for _, a := range args {
		if a == "" || strings.ContainsAny(a, " \t\n'\"$\\;&|<>*?()[]{}#~`") {
			a = "'" + strings.ReplaceAll(a, "'", `'\''`) + "'"
		}
		parts = append(parts, a)
	}
	return strings.Join(parts, " ")
}

func (c *Client) HostContext(ctx context.Context) (HostContext, error) {
	return decode[HostContext](c, ctx, "context", "--all", "--json")
}

// QuickContext is HostContext without the host checks (G5): cheap enough
// to poll. Host health comes from Doctor instead.
func (c *Client) QuickContext(ctx context.Context) (HostContext, error) {
	return decode[HostContext](c, ctx, "context", "--all", "--json", "--no-host")
}

// Stats are every machine's live numbers (G4); ~0.5s while any runs.
func (c *Client) Stats(ctx context.Context) ([]MachineStats, error) {
	return decode[[]MachineStats](c, ctx, "machine", "stats", "--all", "--json")
}

// DiskUse is what flk keeps where (G8).
func (c *Client) DiskUse(ctx context.Context) (DiskUse, error) {
	return decode[DiskUse](c, ctx, "disk", "--json")
}

// Images are flk's container images, one per tag (G10).
func (c *Client) Images(ctx context.Context) ([]Image, error) {
	return decode[[]Image](c, ctx, "images", "--json")
}

func (c *Client) AppContext(ctx context.Context, app string) (AppContext, error) {
	return decode[AppContext](c, ctx, "-a", app, "context", "--json")
}

func (c *Client) Doctor(ctx context.Context) (Doctor, error) {
	return decode[Doctor](c, ctx, "doctor", "--json")
}

func (c *Client) Apps(ctx context.Context) ([]AppSummary, error) {
	return decode[[]AppSummary](c, ctx, "apps", "list", "--json")
}

func (c *Client) Ports(ctx context.Context) (PortsList, error) {
	return decode[PortsList](c, ctx, "ports", "list", "--json")
}

func (c *Client) Status(ctx context.Context, app string) (Status, error) {
	return decode[Status](c, ctx, "-a", app, "status", "--json")
}

func (c *Client) Releases(ctx context.Context, app string) ([]Release, error) {
	return decode[[]Release](c, ctx, "-a", app, "releases", "--json")
}

// ConfigShow is what flk understood of the app's flk.toml, with warnings.
func (c *Client) ConfigShow(ctx context.Context, app string) (ConfigShow, error) {
	return decode[ConfigShow](c, ctx, "-a", app, "config", "show", "--json")
}

// FilesLs lists a directory in a volume (or a backup of it).
func (c *Client) FilesLs(ctx context.Context, app, vol, path, backup string) ([]FileEntry, error) {
	return decode[[]FileEntry](c, ctx, FilesArgs(app, "ls", vol, path, backup, "--json")...)
}

func (c *Client) Volumes(ctx context.Context, app string) ([]Volume, error) {
	return decode[[]Volume](c, ctx, "-a", app, "volumes", "list", "--json")
}

func (c *Client) Backups(ctx context.Context, app string) ([]Backup, error) {
	return decode[[]Backup](c, ctx, "-a", app, "volumes", "backups", "--json")
}

func (c *Client) Secrets(ctx context.Context, app string) ([]Secret, error) {
	return decode[[]Secret](c, ctx, "-a", app, "secrets", "list", "--json")
}

func (c *Client) MachineStatus(ctx context.Context, app, id string) (MachineRecord, error) {
	return decode[MachineRecord](c, ctx, "-a", app, "machine", "status", id)
}

func (c *Client) Help(ctx context.Context) (Help, error) {
	return decode[Help](c, ctx, "help", "--all", "--json")
}

// Logs returns the last n lines of an app's logs (one machine if id is set).
func (c *Client) Logs(ctx context.Context, app, id string, n int) (string, error) {
	args := []string{"-a", app, "logs"}
	if id != "" {
		args = append(args, "-i", id)
	}
	args = append(args, "-n", strconv.Itoa(n), "--no-tail")
	out, err := c.Run(ctx, args...)
	return string(out), err
}
