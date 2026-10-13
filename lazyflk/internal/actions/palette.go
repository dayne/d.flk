package actions

import (
	"strings"

	"lazyflk/internal/flk"
)

// Entry is one command of the palette (SPEC 5.5), from flk's own command
// table, with a form generated from its args and options.
type Entry struct {
	Name    string // "machine start"
	Summary string
	Usage   string
	Action  Action
}

// readOnly commands only look; the palette runs them without asking.
var readOnly = map[string]bool{
	"context": true, "help": true, "completion": true, "doctor": true, "version": true,
	"status": true, "releases": true, "apps list": true, "config show": true,
	"machine list": true, "machine status": true, "machine config": true, "logs": true,
	"ports list": true, "secrets list": true, "volumes list": true, "volumes backups": true,
}

// destroys data: the admin types the name it names.
var destroys = map[string]bool{
	"apps destroy": true, "machine destroy": true, "volumes destroy": true, "volumes restore": true,
}

// needApp commands act on one app; scopeApp ones on one app or all.
var (
	needApp = map[string]bool{
		"deploy": true, "status": true, "releases": true, "config": true, "machine": true, "scale": true,
		"logs": true, "console": true, "ssh": true, "secrets": true, "volumes": true,
	}
	scopeApp = map[string]bool{"context": true, "resume": true, "stop-all": true}
)

// notHere says why a command can't run from lazyflk, if it can't.
var notHere = map[string]string{
	"launch":         "it reads flk.toml from the current directory: run it in a shell in the app's directory",
	"secrets set":    "it would put the value on the command line: use set secret in the app's menu (enter on the app)",
	"secrets import": "it reads KEY=VALUE lines on stdin: use set secret in the app's menu, or a shell",
	"machine revive": "flk runs it itself when a machine exits",
}

// Palette lists every flk command (subcommands, not their parents). app is
// the selected app, the default for -a; readOnlyMode greys out the rest.
func Palette(h flk.Help, app string, readOnlyMode bool) []Entry {
	var out []Entry
	var walk func(c flk.Command, path []string)
	walk = func(c flk.Command, path []string) {
		path = append(append([]string(nil), path...), c.Name)
		if len(c.Subcommands) > 0 {
			for _, s := range c.Subcommands {
				walk(s, path)
			}
			return
		}
		out = append(out, entry(c, path, app, readOnlyMode))
	}
	for _, c := range h.Commands {
		walk(c, nil)
	}
	return out
}

func entry(c flk.Command, path []string, app string, readOnlyMode bool) Entry {
	name := strings.Join(path, " ")
	top := path[0]
	var fields []Field
	if needApp[top] || scopeApp[top] {
		f := Field{Name: "-a", Label: "app", Default: app, Required: needApp[top],
			Help: "the app (-a); the selection's app by default"}
		if !needApp[top] {
			f.Default, f.Help = "", "one app (-a), or empty for every app"
		}
		fields = append(fields, f)
	}
	type arg struct {
		name     string
		variadic bool
	}
	var args []arg
	for i, tok := range argTokens(c.Args) {
		optional := strings.HasPrefix(tok, "[") && strings.HasSuffix(tok, "]")
		if optional {
			tok = tok[1 : len(tok)-1]
		}
		variadic := strings.HasSuffix(tok, "...")
		fname := "arg" + string(rune('0'+i))
		help := "required"
		if optional {
			help = "optional"
		}
		if variadic {
			help += "; several, separated by spaces"
		}
		fields = append(fields, Field{Name: fname, Label: tok, Required: !optional, Help: help})
		args = append(args, arg{fname, variadic})
	}
	type opt struct{ flag, meta string }
	var opts []opt
	for _, o := range c.Options {
		flag, meta := optionSwitch(o.Switches)
		if flag == "" || (flag == "--yes" && destroys[name]) {
			continue // --yes: the typed confirm stands in for it
		}
		f := Field{Name: flag, Label: strings.TrimSpace(flag + " " + meta), Help: o.Description}
		if meta == "" {
			f.Choices = []string{"no", "yes"}
		}
		fields = append(fields, f)
		opts = append(opts, opt{flag, meta})
	}

	help := c.Summary
	if c.Blocks != "" {
		help += ". Blocks: " + c.Blocks
	}
	act := Action{Label: name, Help: help, Fields: fields, Confirm: Ask, Long: true}
	switch {
	case readOnly[name]:
		act.Confirm = NoConfirm
	case destroys[name]:
		act.Confirm = Type
	}
	act.Notes = c.Notes
	if why, ok := notHere[name]; ok {
		act.Disabled = why
	} else if readOnlyMode && !readOnly[name] {
		act.Disabled = "read-only"
	}
	act.build = func(v map[string]string) Command {
		var argv []string
		if a := strings.TrimSpace(v["-a"]); a != "" {
			argv = append(argv, "-a", a)
		}
		argv = append(argv, path...)
		first := ""
		var pos []string
		for _, a := range args {
			val := strings.TrimSpace(v[a.name])
			if val == "" {
				continue
			}
			if first == "" {
				first = val
			}
			if a.variadic {
				pos = append(pos, strings.Fields(val)...)
			} else {
				pos = append(pos, val)
			}
		}
		// a command to run (flk exec -- CMD...): flk's options first, then
		// "--", so the command's own flags stay the command's
		runs := strings.HasSuffix(strings.TrimSpace(c.Args), "CMD...")
		if !runs {
			argv = append(argv, pos...)
		}
		for _, o := range opts {
			val := v[o.flag]
			switch {
			case o.meta == "" && val == "yes":
				argv = append(argv, o.flag)
			case o.meta != "" && strings.TrimSpace(val) != "":
				argv = append(argv, o.flag, strings.TrimSpace(val))
			}
		}
		if runs && len(pos) > 0 {
			argv = append(append(argv, "--"), pos...)
		}
		cmd := Command{Args: argv}
		if destroys[name] {
			cmd.TypeName = first
			if name == "apps destroy" {
				cmd.Args = append(cmd.Args, "--yes")
			}
			cmd.Warn = "This deletes data and can't be undone."
		}
		if c.Blocks != "" {
			if (top == "console" || top == "ssh") && v["--send"] == "" && strings.TrimSpace(v["--command"]) == "" {
				cmd.Interactive = true // the serial console, or a shell (flk 25b23ad)
			} else {
				cmd.Warn = "It runs until you interrupt it: ctrl+c in its output view (esc hides it meanwhile)."
			}
		}
		if name == "exec" && v["--tty"] == "yes" {
			cmd.Interactive, cmd.Warn = true, ""
		}
		if name == "logs" && v["--follow"] == "yes" {
			cmd.Warn = "It follows until you interrupt it: ctrl+c in its output view. (l is the better log view.)"
		}
		return cmd
	}
	return Entry{Name: name, Summary: c.Summary, Usage: c.Usage, Action: act}
}

// argTokens splits "ID|NAME [BACKUP]" or "LOCAL[:REMOTE] [ID]" into its
// arguments, keeping brackets with the word they belong to.
func argTokens(s string) []string {
	var out []string
	depth, cur := 0, ""
	for _, r := range s {
		switch {
		case r == '[':
			depth++
		case r == ']':
			depth--
		case r == ' ' && depth == 0:
			if cur != "" {
				out = append(out, cur)
			}
			cur = ""
			continue
		}
		cur += string(r)
	}
	if cur != "" {
		out = append(out, cur)
	}
	return out
}

// optionSwitch picks an option's long switch and its argument name from
// switches like ["-i", "--instance ID"].
func optionSwitch(sw []string) (flag, meta string) {
	for _, s := range sw {
		f, m, _ := strings.Cut(s, " ")
		if strings.HasPrefix(f, "--") || flag == "" {
			flag, meta = f, m
		}
	}
	return flag, meta
}
