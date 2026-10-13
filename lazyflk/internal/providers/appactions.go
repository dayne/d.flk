package providers

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"

	"lazyflk/internal/actions"
	"lazyflk/internal/flk"
)

// App actions (SPEC 10.4): a .lazyflk.toml next to an app's flk.toml
// names the app's own commands, so game-specific knowledge stays in the
// app's repo:
//
//	[actions]
//	save = "flk -a {app} console {machine} --send save-all --wait-log 'Saved the game'"
//
//	[actions.say]
//	run  = "flk -a {app} console {machine} --send 'say {input}'"
//	help = "broadcast a message to the players"
//
// Placeholders: {app}, {machine} (the selected machine, or the app's
// first), {machine.name}, {volume.NAME} (that volume's file), {dir} (the
// app's directory) and {input} (asked for when the action runs). Each
// runs with sh -c in the app's directory, after showing the expanded
// command and asking.

// AppAction is one entry of [actions].
type AppAction struct {
	Name string
	Run  string
	Help string
}

// LazyflkFile is where an app's actions live, given its flk.toml.
func LazyflkFile(configPath string) string {
	return filepath.Join(filepath.Dir(configPath), ".lazyflk.toml")
}

// LoadAppActions reads an app's .lazyflk.toml; a missing file is no
// actions and no error.
func LoadAppActions(configPath string) ([]AppAction, error) {
	if configPath == "" {
		return nil, nil
	}
	b, err := os.ReadFile(LazyflkFile(configPath))
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return ParseAppActions(string(b))
}

var (
	sectionRE = regexp.MustCompile(`^\[\s*actions(?:\.([A-Za-z0-9_-]+))?\s*\]$`)
	keyRE     = regexp.MustCompile(`^([A-Za-z0-9_-]+)\s*=\s*(.*)$`)
)

// ParseAppActions reads the small TOML subset .lazyflk.toml uses:
// [actions] with name = "command", and [actions.NAME] with run and help.
func ParseAppActions(src string) ([]AppAction, error) {
	byName := map[string]*AppAction{}
	var order []string
	get := func(n string) *AppAction {
		if byName[n] == nil {
			byName[n] = &AppAction{Name: n}
			order = append(order, n)
		}
		return byName[n]
	}
	section, inActions := "", false
	for i, raw := range strings.Split(src, "\n") {
		line := strings.TrimSpace(raw)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if strings.HasPrefix(line, "[") {
			m := sectionRE.FindStringSubmatch(line)
			inActions, section = m != nil, ""
			if m != nil {
				section = m[1]
			}
			continue
		}
		if !inActions {
			continue
		}
		m := keyRE.FindStringSubmatch(line)
		if m == nil {
			return nil, fmt.Errorf(".lazyflk.toml line %d: want name = \"command\"", i+1)
		}
		val, err := tomlString(m[2])
		if err != nil {
			return nil, fmt.Errorf(".lazyflk.toml line %d: %v", i+1, err)
		}
		switch {
		case section == "":
			get(m[1]).Run = val
		case m[1] == "run":
			get(section).Run = val
		case m[1] == "help":
			get(section).Help = val
		}
	}
	var out []AppAction
	for _, n := range order {
		if a := byName[n]; a.Run != "" {
			out = append(out, *a)
		}
	}
	return out, nil
}

// tomlString reads a "basic" or 'literal' TOML string, ignoring a
// trailing # comment.
func tomlString(s string) (string, error) {
	s = strings.TrimSpace(s)
	if strings.HasPrefix(s, "'") {
		end := strings.Index(s[1:], "'")
		if end < 0 {
			return "", fmt.Errorf("unterminated string")
		}
		return s[1 : end+1], nil
	}
	if !strings.HasPrefix(s, `"`) {
		return "", fmt.Errorf("want a quoted string")
	}
	for i := 1; i < len(s); i++ {
		switch s[i] {
		case '\\':
			i++
		case '"':
			return strconv.Unquote(s[:i+1])
		}
	}
	return "", fmt.Errorf("unterminated string")
}

var (
	placeholderRE = regexp.MustCompile(`\{([a-z]+(?:\.[A-Za-z0-9_-]+)?)\}`)
	safeValue     = regexp.MustCompile(`^[A-Za-z0-9._/:@+=-]*$`)
	// typed input may also have spaces and plain punctuation, but nothing
	// the shell would read (quotes, $, `, \, ;, &, |, <, >, parentheses)
	safeInput = regexp.MustCompile(`^[A-Za-z0-9 ._/:@+=,!?%#*\[\]-]*$`)
)

// AppActionItems turns an app's actions into menu actions: keys 1-9, an
// {input} field when the command asks for one, and sh -c in dir.
func AppActionItems(list []AppAction, a flk.App, machine *flk.Machine, dir string) []actions.Action {
	var out []actions.Action
	for i, act := range list {
		key := ""
		if i < 9 {
			key = strconv.Itoa(i + 1)
		}
		help := act.Help
		if help == "" {
			help = "from .lazyflk.toml: " + act.Run
		}
		needsInput := strings.Contains(act.Run, "{input}")
		act := act
		out = append(out, actions.Custom(key, act.Name, help, needsInput,
			func(input string) (actions.Command, string) {
				line, err := Expand(act.Run, a, machine, dir, input)
				if err != "" {
					return actions.Command{}, err
				}
				if strings.Contains(dir, "'") {
					return actions.Command{}, "the app's directory has a ' in its name"
				}
				return actions.Command{Program: "sh", Args: []string{"-c", "cd '" + dir + "' && " + line},
					Warn: "Runs " + act.Name + " from " + filepath.Join(dir, ".lazyflk.toml") + " with sh, in the app's directory."}, ""
			}))
	}
	return out
}

// Expand fills an action's placeholders. Values from flk must look like
// names or paths, and typed input can't contain anything the shell
// interprets, so a placeholder can't change the command's shape.
func Expand(cmd string, a flk.App, machine *flk.Machine, dir, input string) (string, string) {
	m := machine
	if m == nil && len(a.Machines) > 0 {
		m = &a.Machines[0]
	}
	var problem string
	out := placeholderRE.ReplaceAllStringFunc(cmd, func(ph string) string {
		key := ph[1 : len(ph)-1]
		var v string
		switch {
		case key == "app":
			v = a.Name
		case key == "dir":
			v = dir
		case key == "machine" || key == "machine.name":
			if m == nil {
				problem = "the app has no machine for {" + key + "}"
				return ph
			}
			v = m.ID
			if key == "machine.name" {
				v = m.Name
			}
		case strings.HasPrefix(key, "volume."):
			name := strings.TrimPrefix(key, "volume.")
			for _, vol := range a.Volumes {
				if vol.Name == name {
					v = vol.Path
				}
			}
			if v == "" {
				problem = "the app has no volume " + name
				return ph
			}
		case key == "input":
			if !safeInput.MatchString(input) {
				problem = "the input can't contain quotes, $, `, \\, ;, &, |, <, > or parentheses"
				return ph
			}
			return input
		default:
			names := []string{"{app}", "{machine}", "{machine.name}", "{volume.NAME}", "{dir}", "{input}"}
			sort.Strings(names)
			problem = "unknown placeholder " + ph + " (known: " + strings.Join(names, " ") + ")"
			return ph
		}
		if !safeValue.MatchString(v) {
			problem = fmt.Sprintf("%s is %q, which isn't safe to put in a command", ph, v)
			return ph
		}
		return v
	})
	return out, problem
}
