// lazyflk is a terminal UI for hosts running flk. See SPEC.md.
package main

import (
	"context"
	"flag"
	"fmt"
	"io/fs"
	"os"
	"time"

	tea "charm.land/bubbletea/v2"

	"lazyflk/fixtures"
	"lazyflk/internal/flk"
	"lazyflk/internal/host"
	"lazyflk/internal/ui"
)

func main() {
	fs := flag.NewFlagSet("lazyflk", flag.ContinueOnError)
	fs.Usage = func() {
		fmt.Fprintln(fs.Output(), "usage: lazyflk [--demo] [--read-only] [--refresh 5s] [--flk PATH]")
		fs.PrintDefaults()
	}
	demo := fs.Bool("demo", false, "show captured output from fixtures/ instead of running flk")
	readOnly := fs.Bool("read-only", false, "hide all actions")
	refresh := fs.Duration("refresh", 5*time.Second, "how often to reload flk context --all --json (0: load once)")
	flkPath := fs.String("flk", "", "flk binary (default: $LAZYFLK_FLK, then PATH)")
	if err := fs.Parse(os.Args[1:]); err != nil {
		if err == flag.ErrHelp {
			os.Exit(0)
		}
		os.Exit(2)
	}
	if fs.NArg() > 0 {
		fmt.Fprintf(os.Stderr, "Error: unexpected argument %q\n", fs.Arg(0))
		os.Exit(2)
	}

	var runner flk.Runner
	disk := host.DF
	if *demo {
		runner = flk.NewFake(fixtures.FS)
		disk = demoDisk
	} else {
		path, err := flk.FindFlk(*flkPath)
		if err != nil {
			fmt.Fprintln(os.Stderr, "Error:", err)
			os.Exit(1)
		}
		runner = flk.Exec{Path: path}
	}

	m := ui.New(ui.Options{Client: flk.New(runner), Disk: disk, Demo: *demo, ReadOnly: *readOnly, Refresh: *refresh})
	if _, err := tea.NewProgram(m).Run(); err != nil {
		fmt.Fprintln(os.Stderr, "Error:", err)
		os.Exit(1)
	}
}

// demoDisk answers df from the captured fixtures/df.txt.
func demoDisk(_ context.Context, paths []string) ([]host.Disk, error) {
	out, err := fs.ReadFile(fixtures.FS, "df.txt")
	if err != nil {
		return nil, err
	}
	return host.ParseDF(string(out), paths)
}
