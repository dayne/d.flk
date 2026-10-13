// lazyflk is a terminal UI for hosts running flk. See SPEC.md.
package main

import (
	"flag"
	"fmt"
	"os"
	"time"

	tea "charm.land/bubbletea/v2"

	"lazyflk/fixtures"
	"lazyflk/internal/flk"
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
	if *demo {
		runner = flk.NewFake(fixtures.FS)
	} else {
		path, err := flk.FindFlk(*flkPath)
		if err != nil {
			fmt.Fprintln(os.Stderr, "Error:", err)
			os.Exit(1)
		}
		runner = flk.Exec{Path: path}
	}

	m := ui.New(ui.Options{Client: flk.New(runner), Demo: *demo, ReadOnly: *readOnly, Refresh: *refresh})
	if _, err := tea.NewProgram(m).Run(); err != nil {
		fmt.Fprintln(os.Stderr, "Error:", err)
		os.Exit(1)
	}
}
