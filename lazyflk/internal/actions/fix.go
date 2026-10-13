package actions

import (
	"regexp"
	"strings"

	"lazyflk/internal/flk"
)

var (
	flkRE   = regexp.MustCompile(`\bflk [a-z]`)
	parenRE = regexp.MustCompile(`\([^()]*\)`)
	tokenRE = regexp.MustCompile(`^[A-Za-z0-9._/:=@+-]+$`)
)

// flk's top-level commands (flk help --all), so prose like "flk doesn't
// know" isn't taken for one.
var commands = map[string]bool{}

func init() {
	for _, c := range strings.Fields("context help completion setup doctor version resume stop-all launch " +
		"deploy status releases apps config machine scale logs console ssh proxy ports secrets volumes") {
		commands[c] = true
	}
}

// prose ends a command quoted in a sentence ("run flk launch once in ...").
var prose = map[string]bool{"once": true, "in": true, "then": true, "to": true, "and": true, "or": true,
	"if": true, "when": true, "from": true, "for": true, "the": true, "its": true, "it": true}

// command cuts a quoted flk command out of the text after "flk ".
func command(match string) []string {
	var words []string
	for i, w := range strings.Fields(match)[1:] {
		w = strings.TrimRight(w, ".:")
		if (i == 0 && !commands[w]) || (i > 0 && prose[w]) {
			break
		}
		words = append(words, w)
	}
	return words
}

// Fix is the one-key fix for a next_step from `flk context --all --json`
// (SPEC 3.4), when the step names a command. Commands of a known, safe
// shape run (scoped to the step's app); root steps and anything else are
// offered for copying. ok is false when the step names no command.
func Fix(step string, apps []flk.App) (act Action, ok bool) {
	var a *flk.App
	text := step
	for i := range apps {
		if rest, found := strings.CutPrefix(step, apps[i].Name+": "); found {
			a, text = &apps[i], rest
			break
		}
	}
	if cmd := rootStep(text); cmd != "" {
		return Action{Key: "f", Label: "copy: " + cmd, Help: "needs root, so lazyflk doesn't run it: paste it in a shell",
			View: ViewCopy, Copy: cmd}, true
	}
	// "(or flk deploy)", "(run 2 times)": asides, not the fix
	var words []string
	plain := parenRE.ReplaceAllString(text, "")
	for _, at := range flkRE.FindAllStringIndex(plain, -1) {
		m, _, _ := strings.Cut(plain[at[0]:], ";")
		if i := strings.IndexAny(m, ",()"); i >= 0 {
			m = m[:i]
		}
		if w := command(m); len(w) > 0 {
			words = w
		}
	}
	if words == nil {
		return Action{}, false
	}
	line := "flk " + strings.Join(words, " ")
	if args, long, why := runnable(words, a); args != nil {
		act := Action{Key: "f", Label: "fix: " + flk.CommandLine(args...), Help: text,
			Confirm: Ask, Long: long, Disabled: why,
			build: func(map[string]string) Command { return Command{Args: args, Warn: text} }}
		return act, true
	}
	return Action{Key: "f", Label: "copy: " + line, Help: "lazyflk doesn't run this one: paste it in a shell",
		View: ViewCopy, Copy: line}, true
}

// runnable turns a step's command into argv when lazyflk may run it: a
// short allow-list of shapes, scoped to the app (-a) the step is about.
func runnable(words []string, a *flk.App) (args []string, long bool, disabled string) {
	for _, w := range words {
		if !tokenRE.MatchString(w) {
			return nil, false, ""
		}
	}
	shape := strings.Join(words, " ")
	scoped := func() []string {
		if a == nil {
			return words
		}
		return append([]string{"-a", a.Name}, words...)
	}
	n := len(words)
	switch {
	case shape == "resume":
		return scoped(), true, ""
	case shape == "ports sync", shape == "apps prune":
		return words, false, ""
	case n == 3 && words[0] == "machine" && words[1] == "start" && a != nil:
		return scoped(), true, ""
	case n == 3 && words[0] == "scale" && words[1] == "count" && a != nil:
		return scoped(), true, ""
	case n == 5 && words[0] == "volumes" && words[1] == "create" && words[3] == "--size" && a != nil:
		return scoped(), true, ""
	case shape == "deploy" && a != nil:
		if a.ConfigPath == "" {
			disabled = "flk doesn't know where its flk.toml is: run flk deploy once in its directory"
		}
		return scoped(), true, disabled
	}
	return nil, false, ""
}
