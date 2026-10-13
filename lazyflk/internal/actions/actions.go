// Package actions is lazyflk's action table (SPEC 5.4): for a selection,
// everything that can be done to it, each as the exact flk command it
// runs. It knows nothing about the screen; the UI shows these, asks for
// fields and confirmation, then runs Command.Args.
package actions

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"

	"lazyflk/internal/flk"
)

// Kind is what's selected.
type Kind int

const (
	App Kind = iota
	Machine
	Volume
	Ports
	Host
)

// Target is the selection, with what flk reported about it.
type Target struct {
	Kind       Kind
	App        flk.App     // all kinds but Host
	Machine    flk.Machine // Machine
	Volume     flk.Volume  // Volume
	Apps       []flk.App   // Host: every app
	Problems   []flk.DoctorCheck
	Backups    []flk.Backup  // the app's backups; nil until loaded
	BackupsErr string        // why they couldn't be listed
	Releases   []flk.Release // the app's releases; nil until loaded
	StateDir   string        // flk's state dir: volumes outside it are external
}

// External reports a volume whose file lives outside flk's state dir
// (created with --path, or imported); flk keeps such files unless told
// otherwise. Same rule as flk's App.external_volume?.
func External(v flk.Volume, stateDir string) bool {
	return v.External || (stateDir != "" && !strings.HasPrefix(v.Path, strings.TrimRight(stateDir, "/")+"/"))
}

// Confirm is how much the admin must do before an action runs.
type Confirm int

const (
	NoConfirm Confirm = iota
	Ask               // y runs it
	Type              // type a name (destroying data)
)

// Field is one input of an action's form.
type Field struct {
	Name     string // key in the values map
	Label    string
	Help     string
	Default  string
	Choices  []string // pick one; the first is the default
	Secret   bool     // never shown, sent on stdin
	Required bool
	Number   bool // a whole number
}

// Command is what an action runs. Stdin carries secret values, so they
// never appear in Args, on screen or in the command log.
type Command struct {
	Args  []string
	Stdin string
	Warn  string // shown when confirming: what this will do
	// TypeName, if set, must be typed to confirm (overrides the action's).
	TypeName string
	// Interactive commands get the terminal (console attach).
	Interactive bool
	// Program is what runs: "" for flk, else another tool on the host
	// (podman, sh for an app's own actions).
	Program string
}

// Line is the command as the admin would type it.
func (c Command) Line() string {
	if c.Program != "" {
		return flk.CommandLineFor(c.Program, c.Args...)
	}
	return flk.CommandLine(c.Args...)
}

// View names an action the UI handles itself instead of running flk.
type View string

const (
	ViewLogs   View = "logs"
	ViewRecord View = "record" // the machine's Record tab
	ViewHealth View = "health" // the host's Health tab
	ViewCopy   View = "copy"   // copy Copy to the clipboard
	ViewAttach View = "attach" // the console, in the real terminal
	ViewSend   View = "send"   // type one line into the console
)

type Action struct {
	Key      string // menu shortcut
	Label    string
	Help     string // one line: what it does
	Disabled string // why it can't run now ("" when it can)
	Fields   []Field
	Confirm  Confirm
	TypeName string // what to type for Confirm == Type
	Long     bool   // takes a while; the UI keeps its output in view
	View     View
	Copy     string   // for ViewCopy
	Notes    []string // flk's notes on the command, shown in its form
	Logs     *Command // for ViewLogs from a provider: the command to follow
	check    func(vals map[string]string) string
	build    func(vals map[string]string) Command
}

// Command builds the command from the form's values (defaults filled in).
func (a Action) Command(vals map[string]string) Command {
	if a.build == nil {
		return Command{}
	}
	full := map[string]string{}
	for _, f := range a.Fields {
		full[f.Name] = f.Default
		if len(f.Choices) > 0 && f.Default == "" {
			full[f.Name] = f.Choices[0]
		}
	}
	for k, v := range vals {
		full[k] = v
	}
	return a.build(full)
}

// Check reports what's wrong with the form's values, or "".
func (a Action) Check(vals map[string]string) string {
	if a.check != nil {
		if why := a.check(vals); why != "" {
			return why
		}
	}
	for _, f := range a.Fields {
		v := strings.TrimSpace(vals[f.Name])
		if v == "" {
			v = f.Default
		}
		if f.Required && v == "" {
			return f.Label + " is required"
		}
		if f.Number && v != "" {
			if n, err := strconv.Atoi(v); err != nil || n < 0 {
				return f.Label + " must be a whole number"
			}
		}
	}
	return ""
}

func fixed(args ...string) func(map[string]string) Command {
	return func(map[string]string) Command { return Command{Args: args} }
}

func app(a flk.App, rest ...string) []string { return append([]string{"-a", a.Name}, rest...) }

func machineRef(m flk.Machine) string { return m.ID }

func machineName(m flk.Machine) string {
	if m.Name != "" {
		return m.ID + " [" + m.Name + "]"
	}
	return m.ID
}

// For lists the actions for a target, available ones and greyed-out ones.
func For(t Target) []Action {
	switch t.Kind {
	case Machine:
		return machineActions(t.App, t.Machine)
	case App:
		return appActions(t)
	case Volume:
		return volumeActions(t)
	case Ports:
		return []Action{portsSync()}
	case Host:
		return hostActions(t)
	}
	return nil
}

func machineActions(a flk.App, m flk.Machine) []Action {
	id := machineRef(m)
	start := Action{Key: "s", Label: "start", Help: "boot it",
		build: fixed(app(a, "machine", "start", id)...)}
	stop := Action{Key: "S", Label: "stop", Help: "stop gracefully; it stays stopped, also after reboots",
		Confirm: Ask, build: func(map[string]string) Command {
			return Command{Args: app(a, "machine", "stop", id),
				Warn: fmt.Sprintf("%s stops (SIGTERM to the app, killed after its kill_timeout).", machineName(m))}
		}}
	restart := Action{Key: "r", Label: "restart", Help: "stop, then boot",
		Confirm: Ask, build: func(map[string]string) Command {
			return Command{Args: app(a, "machine", "restart", id),
				Warn: fmt.Sprintf("%s stops and boots again.", machineName(m))}
		}}
	switch {
	case m.Started():
		start.Disabled = "already running"
	case m.ShouldRun():
		stop.Help = "it isn't running, but should be: this records it as stopped, so resume leaves it alone"
		restart.Disabled = "not running: start it"
	default:
		stop.Disabled = "already stopped"
		restart.Disabled = "not running: start it"
	}
	console := Action{Key: "c", Label: "console", Help: "attach to its serial console (detach: Ctrl-b d)", View: ViewAttach}
	send := Action{Key: ">", Label: "send a line", Help: "type one line into the app's stdin and watch the log answer (console --send)", View: ViewSend}
	if !m.Started() {
		console.Disabled, send.Disabled = "not running", "not running"
	}
	return []Action{start, stop, restart,
		{Key: "l", Label: "logs", Help: "follow its console output", View: ViewLogs},
		console, send,
		{Key: "R", Label: "record", Help: "flk machine status: its record and state", View: ViewRecord},
	}
}

func appActions(t Target) []Action {
	a := t.App
	running, should := 0, 0
	for _, m := range a.Machines {
		if m.Started() {
			running++
		}
		if m.ShouldRun() {
			should++
		}
	}
	deploy := Action{Key: "d", Label: "deploy", Help: "build the image and roll machines to a new release",
		Long: true, Confirm: Ask,
		Fields: []Field{{Name: "image", Label: "image", Help: "deploy this image instead of building (empty: build from the app's Dockerfile)"},
			checksField()},
		build: func(v map[string]string) Command {
			args := app(a, "deploy")
			if img := strings.TrimSpace(v["image"]); img != "" {
				args = append(args, "--image", img)
			}
			warn := "Builds from " + a.ConfigPath + ", then replaces each machine with one on the new release."
			if running > 0 {
				warn += fmt.Sprintf(" Restarts %s.", plural(running, "running machine"))
			}
			return withChecks(Command{Args: args, Warn: warn}, v)
		}}
	if a.ConfigPath == "" {
		deploy.Disabled = "flk doesn't know where its flk.toml is: run flk deploy once in its directory"
	}
	scale := ""
	if a.Scale != nil {
		scale = strconv.Itoa(*a.Scale)
	} else {
		scale = strconv.Itoa(len(a.Machines))
	}
	resume := Action{Key: "u", Label: "resume", Help: "start its machines that should be running",
		build: fixed(app(a, "resume")...)}
	if should == 0 {
		resume.Disabled = "nothing to resume"
	}
	stopAll := Action{Key: "S", Label: "stop all", Help: "stop its running machines; resume brings them back",
		Confirm: Ask, Long: true, build: func(map[string]string) Command {
			return Command{Args: app(a, "stop-all"),
				Warn: fmt.Sprintf("Stops %s of %s. They stay meant to run: resume (u) starts them again.", plural(running, "machine"), a.Name)}
		}}
	if running == 0 {
		stopAll.Disabled = "nothing running"
	}
	unset := Action{Key: "U", Label: "unset secret", Help: "remove a secret",
		Confirm: Ask,
		Fields: []Field{{Name: "name", Label: "name", Choices: a.Secrets},
			stageField(running)},
		build: func(v map[string]string) Command {
			args := app(a, "secrets", "unset", v["name"])
			return secretCommand(args, v, running, "")
		}}
	if len(a.Secrets) == 0 {
		unset.Disabled = "no secrets"
	}
	destroy := Action{Key: "D", Label: "destroy app", Help: "delete the app, its machines, releases and volumes",
		Confirm: Type, TypeName: a.Name, build: func(map[string]string) Command {
			warn := fmt.Sprintf("Deletes %s: %s, %s and its releases.", a.Name,
				plural(len(a.Machines), "machine"), plural(len(a.Volumes), "volume"))
			for _, v := range a.Volumes {
				if External(v, t.StateDir) {
					warn += " External volume files are kept."
					break
				}
			}
			return Command{Args: []string{"apps", "destroy", a.Name, "--yes"}, Warn: warn + " This can't be undone."}
		}}
	acts := []Action{deploy, rollback(a, t.Releases, running),
		{Key: "c", Label: "scale", Help: "set the number of machines",
			Confirm: Ask, Long: true,
			Fields: []Field{{Name: "count", Label: "machines", Default: scale, Required: true, Number: true}},
			build: func(v map[string]string) Command {
				n, _ := strconv.Atoi(strings.TrimSpace(v["count"]))
				warn := fmt.Sprintf("%s goes from %d to %s.", a.Name, len(a.Machines), plural(n, "machine"))
				if n < len(a.Machines) {
					warn += " Extra machines are destroyed; their volumes are kept, unattached."
				}
				return Command{Args: app(a, "scale", "count", strconv.Itoa(n)), Warn: warn}
			}},
		resume, stopAll,
		{Key: "e", Label: "set secret", Help: "set a secret; the value goes to flk on stdin, never on the command line",
			Confirm: Ask,
			Fields: []Field{
				{Name: "name", Label: "name", Required: true, Help: "an env var name, e.g. API_KEY"},
				{Name: "value", Label: "value", Secret: true, Help: "never shown or logged"},
				stageField(running)},
			build: func(v map[string]string) Command {
				args := app(a, "secrets", "set", strings.TrimSpace(v["name"])+"=-")
				return secretCommand(args, v, running, v["value"]+"\n")
			}},
		unset,
		volumeCreate(a, ""), volumeImport(a), backup(t, nil),
		{Key: "l", Label: "logs", Help: "follow all its machines' console output", View: ViewLogs},
		destroy,
	}
	return acts
}

// checksField is --no-rollback: what happens to a machine that fails its
// health checks.
func checksField() Field {
	return Field{Name: "checks", Label: "failing checks", Choices: []string{"roll back", "leave it"},
		Help: "a machine that fails its health checks goes back to its old release; leave it: stays on the new one, to debug (--no-rollback)"}
}

func withChecks(c Command, v map[string]string) Command {
	if v["checks"] == "leave it" {
		c.Args = append(c.Args, "--no-rollback")
		c.Warn += " A machine that fails its health checks stays on the new release (--no-rollback)."
	}
	return c
}

// rollback makes a new release from an older one's image and config, and
// rolls it out like a deploy (flk releases rollback).
func rollback(a flk.App, rels []flk.Release, running int) Action {
	cur := 0
	if a.Release != nil {
		cur = a.Release.Version
	}
	// a machine left on a failed release (deploy --no-rollback) goes back
	// to the current release, so it's offered first (flk 3fd7177)
	stranded := false
	for _, m := range a.Machines {
		for _, r := range rels {
			if r.Version == m.Release && r.Version > cur && r.Failed() {
				stranded = true
			}
		}
	}
	// releases it can go to, newest first: kept image, not failed, not current
	var to []string
	for i := len(rels) - 1; i >= 0; i-- {
		if r := rels[i]; r.Image && !r.Failed() && (r.Version != cur || stranded) {
			to = append(to, fmt.Sprintf("v%d", r.Version))
		}
	}
	act := Action{Key: "r", Label: "roll back", Help: "back to an older release's image and config, rolled out like a deploy",
		Confirm: Ask, Long: true,
		Fields: []Field{{Name: "to", Label: "to", Choices: to,
			Help: "a release whose image is kept ([flk] keep_releases); volumes stay as they are"}, checksField()},
		build: func(v map[string]string) Command {
			args := app(a, "releases", "rollback")
			what := "the release before the current one"
			if r := strings.TrimSpace(v["to"]); r != "" {
				args, what = append(args, r), r
			}
			warn := fmt.Sprintf("Makes a new release with %s's image and machine config, then replaces each machine like a deploy.", what)
			if running > 0 {
				warn += fmt.Sprintf(" Restarts %s.", plural(running, "running machine"))
			}
			warn += " Volumes stay as they are: data written since isn't rolled back."
			return withChecks(Command{Args: args, Warn: warn}, v)
		}}
	switch {
	case cur == 0:
		act.Disabled = "no release yet"
	case rels != nil && len(to) == 0:
		act.Disabled = "no kept release to go back to (keep more with [flk] keep_releases)"
	case rels == nil:
		act.Fields[0].Help = "loading the releases… (empty: the one before the current)"
	}
	return act
}

func stageField(running int) Field {
	f := Field{Name: "stage", Label: "apply", Choices: []string{"now", "later"},
		Help: "now restarts running machines; later stages it for the next start or deploy (--stage)"}
	if running == 0 {
		f.Help = "no machine is running, so it applies on the next start either way"
	}
	return f
}

func secretCommand(args []string, v map[string]string, running int, stdin string) Command {
	c := Command{Args: args, Stdin: stdin}
	if v["stage"] == "later" {
		c.Args = append(c.Args, "--stage")
		c.Warn = "Staged: running machines keep the old value until they restart or the app deploys."
	} else if running > 0 {
		c.Warn = fmt.Sprintf("Restarts %s to pick it up.", plural(running, "running machine"))
	}
	return c
}

func volumeCreate(a flk.App, name string) Action {
	return Action{Key: "n", Label: "new volume", Help: "create a volume for [[mounts]] source = NAME",
		Long: true,
		Fields: []Field{
			{Name: "name", Label: "name", Default: name, Required: true, Help: "the [[mounts]] source it's for"},
			{Name: "size", Label: "size GB", Default: "1", Required: true, Number: true},
			{Name: "path", Label: "file", Help: "put the image here, e.g. on a bigger disk (empty: flk's state dir)"},
			{Name: "from", Label: "copy from", Help: "fill it with a copy of this directory (empty: start empty)"},
		},
		build: func(v map[string]string) Command {
			args := app(a, "volumes", "create", strings.TrimSpace(v["name"]), "--size", strings.TrimSpace(v["size"]))
			if p := strings.TrimSpace(v["path"]); p != "" {
				args = append(args, "--path", p)
			}
			if d := strings.TrimSpace(v["from"]); d != "" {
				args = append(args, "--from-dir", d)
			}
			return Command{Args: args}
		}}
}

func volumeImport(a flk.App) Action {
	return Action{Key: "i", Label: "import volume", Help: "register an existing ext4 image; flk never deletes it",
		Fields: []Field{
			{Name: "name", Label: "name", Required: true, Help: "the [[mounts]] source it's for"},
			{Name: "path", Label: "image file", Required: true, Help: "an existing ext4 image"},
		},
		build: func(v map[string]string) Command {
			return Command{Args: app(a, "volumes", "import", strings.TrimSpace(v["name"]), "--path", strings.TrimSpace(v["path"]))}
		}}
}

// backup copies one volume, or all of the app's when v is nil.
func backup(t Target, v *flk.Volume) Action {
	a := t.App
	args := app(a, "volumes", "backup")
	what := "all of " + a.Name + "'s volumes"
	if v != nil {
		args = append(args, v.Name)
		what = v.Name
	}
	act := Action{Key: "b", Label: "back up", Help: "copy " + what + " to the backup dir, then prune old copies",
		Confirm: Ask, Long: true, build: func(map[string]string) Command {
			warn := "Copies " + what + ". In stop mode (the default) the machine using a volume stops for the copy and starts again; [flk.backup] mode in flk.toml can make it live or pause."
			return Command{Args: args, Warn: warn}
		}}
	if len(a.Volumes) == 0 {
		act.Disabled = "no volumes"
	}
	return act
}

// volumeNameRE is flk's rule for volume names.
var volumeNameRE = regexp.MustCompile(`^[a-z0-9_]{1,30}$`)

func or(s, fallback string) string {
	if s == "" {
		return fallback
	}
	return s
}

// restoredName is restore --as's default: NAME_restored, within 30.
func restoredName(name string) string {
	return name[:min(len(name), 30-len("_restored"))] + "_restored"
}

func volumeActions(t Target) []Action {
	a, v := t.App, t.Volume
	var user *flk.Machine
	for i, m := range a.Machines {
		if m.ID == v.AttachedMachine {
			user = &a.Machines[i]
		}
	}
	inUse := ""
	if user != nil && user.Started() {
		inUse = fmt.Sprintf("machine %s is using it: stop it first", machineName(*user))
	}

	var backups []string
	for _, b := range t.Backups {
		if b.VolumeID == v.ID || (b.VolumeID == "" && b.Volume == v.Name) {
			backups = append(backups, b.File)
		}
	}
	restore := Action{Key: "t", Label: "restore", Help: "replace its data with a backup; the current image is kept aside",
		Confirm: Type, TypeName: v.Name, Long: true,
		Fields: []Field{{Name: "backup", Label: "backup", Choices: backups,
			Help: "newest first (flk volumes backups)"}},
		build: func(val map[string]string) Command {
			args := app(a, "volumes", "restore", v.Name)
			if b := val["backup"]; b != "" {
				args = append(args, b)
			}
			return Command{Args: args, Warn: fmt.Sprintf("Replaces %s's data with the backup. The current image is kept next to it (.before-restore-…) until you delete it.", v.Name)}
		}}
	switch {
	case inUse != "":
		restore.Disabled = inUse
	case t.Backups == nil && t.BackupsErr != "":
		restore.Disabled = t.BackupsErr
	case t.Backups == nil:
		restore.Disabled = "loading its backups…"
	case len(backups) == 0:
		restore.Disabled = "no backups of it yet"
	}
	extend := Action{Key: "g", Label: "extend", Help: "grow it and its filesystem (grow only)",
		Confirm: Ask, Long: true,
		Fields: []Field{{Name: "size", Label: "new size GB", Default: strconv.Itoa(v.SizeGB + 1), Required: true, Number: true}},
		build: func(val map[string]string) Command {
			size := strings.TrimSpace(val["size"])
			return Command{Args: app(a, "volumes", "extend", v.Name, "--size", size),
				Warn: fmt.Sprintf("Grows %s from %dGB to %sGB (sparse: no space is used until written).", v.Name, v.SizeGB, size)}
		}}
	if inUse != "" {
		extend.Disabled = inUse
	}

	restoreAs := Action{Key: "a", Label: "restore as new", Help: "copy a backup into a new volume, to test it or look inside; nothing stops",
		Confirm: Ask, Long: true,
		Fields: []Field{{Name: "backup", Label: "backup", Choices: backups, Help: "newest first"},
			{Name: "as", Label: "new volume", Default: restoredName(v.Name), Required: true,
				Help: "its name; if it's a [[mounts]] source, the next machine that needs one may attach it"},
			{Name: "path", Label: "file", Help: "put its image here (empty: flk's state dir)"}},
		check: func(val map[string]string) string {
			n := strings.TrimSpace(val["as"])
			switch {
			case n == v.Name:
				return "pick a new name: restore (t) replaces " + v.Name + " itself"
			case !volumeNameRE.MatchString(n):
				return "volume names: up to 30 lowercase letters, digits, underscores"
			}
			return ""
		},
		build: func(val map[string]string) Command {
			as := strings.TrimSpace(val["as"])
			args := app(a, "volumes", "restore", v.Name)
			if b := val["backup"]; b != "" {
				args = append(args, b)
			}
			args = append(args, "--as", as)
			if p := strings.TrimSpace(val["path"]); p != "" {
				args = append(args, "--path", p)
			}
			return Command{Args: args, Warn: fmt.Sprintf("Copies the backup into a new, unattached volume %s (as big as %s). Nothing stops, and %s isn't touched.", as, v.Name, v.Name)}
		}}
	verify := Action{Key: "v", Label: "verify", Help: "check backups without changing them: e2fsck -n, then the app's verify hook",
		Long: true,
		Fields: []Field{{Name: "backup", Label: "backup", Choices: append(append([]string{}, backups...), "all"),
			Help: "one backup (newest first), or all of them"}},
		build: func(val map[string]string) Command {
			args := app(a, "volumes", "verify", v.Name)
			switch b := val["backup"]; b {
			case "all":
				args = append(args, "--all")
			case "":
			default:
				args = append(args, "--backup", b)
			}
			return Command{Args: args}
		}}
	cp := Action{Key: "c", Label: "copy", Help: "copy a backup off this disk or host (rsync), then prune old copies there",
		Confirm: Ask, Long: true,
		Fields: []Field{{Name: "backup", Label: "backup", Choices: backups, Help: "newest first"},
			{Name: "dest", Label: "to", Help: "a dir or HOST:DIR (empty: backup_copy_to in ~/.config/flk/host.toml)"}},
		build: func(val map[string]string) Command {
			args := app(a, "volumes", "copy", v.Name)
			if b := val["backup"]; b != "" {
				args = append(args, "--backup", b)
			}
			dest := strings.TrimSpace(val["dest"])
			if dest != "" {
				args = append(args, "--dest", dest)
			}
			return Command{Args: args, Warn: "Copies the backup to " + or(dest, "backup_copy_to") +
				"/" + a.Name + "/" + v.Name + "/ (skipped if it's there), then deletes the oldest copies there beyond the copy keep count."}
		}}
	for _, x := range []*Action{&restoreAs, &verify, &cp} {
		switch {
		case t.Backups == nil && t.BackupsErr != "":
			x.Disabled = t.BackupsErr
		case t.Backups == nil:
			x.Disabled = "loading its backups…"
		case len(backups) == 0:
			x.Disabled = "no backups of it yet"
		}
	}

	acts := []Action{backup(t, &v), verify, cp, restore, restoreAs, extend}
	attached := ""
	if v.AttachedMachine != "" {
		attached = "attached to machine " + v.AttachedMachine + ": destroy that machine (or scale down) first"
	}
	if External(v, t.StateDir) {
		unreg := Action{Key: "D", Label: "unregister", Help: "forget it; the file stays at " + v.Path,
			Confirm: Type, TypeName: v.Name, Disabled: attached,
			build: func(map[string]string) Command {
				return Command{Args: app(a, "volumes", "destroy", v.ID),
					Warn: "flk forgets " + v.Name + "; the file stays at " + v.Path + "."}
			}}
		del := Action{Key: "X", Label: "destroy with data", Help: "forget it and delete " + v.Path,
			Confirm: Type, TypeName: v.Name, Disabled: attached,
			build: func(map[string]string) Command {
				return Command{Args: app(a, "volumes", "destroy", v.ID, "--delete-data"),
					Warn: "Deletes " + v.Path + " and everything in it. This can't be undone."}
			}}
		acts = append(acts, unreg, del)
	} else {
		acts = append(acts, Action{Key: "D", Label: "destroy", Help: "delete it and its data",
			Confirm: Type, TypeName: v.Name, Disabled: attached,
			build: func(map[string]string) Command {
				return Command{Args: app(a, "volumes", "destroy", v.ID),
					Warn: "Deletes " + v.Name + " (" + v.Path + ") and everything in it. This can't be undone."}
			}})
	}
	return append(acts, volumeCreate(a, v.Name))
}

func portsSync() Action {
	return Action{Key: "p", Label: "sync ports", Help: "rewrite the host's port map from the running machines",
		build: fixed("ports", "sync")}
}

func hostActions(t Target) []Action {
	running, should := 0, 0
	for _, a := range t.Apps {
		for _, m := range a.Machines {
			if m.Started() {
				running++
			}
			if m.ShouldRun() {
				should++
			}
		}
	}
	resume := Action{Key: "u", Label: "resume all", Help: "start every machine that should be running",
		build: fixed("resume")}
	if should == 0 {
		resume.Disabled = "nothing to resume"
	}
	stop := Action{Key: "S", Label: "stop all", Help: "stop every running machine, remembering to resume them",
		Confirm: Ask, Long: true, build: func(map[string]string) Command {
			return Command{Args: []string{"stop-all"},
				Warn: fmt.Sprintf("Stops %s on this host (what a shutdown does). resume (u) starts them again.", plural(running, "running machine"))}
		}}
	if running == 0 {
		stop.Disabled = "nothing running"
	}
	acts := []Action{resume, stop, portsSync(),
		{Key: "P", Label: "prune images", Help: "remove container images of apps that no longer exist",
			Confirm: Ask, build: func(map[string]string) Command {
				return Command{Args: []string{"apps", "prune"}, Warn: "Removes image tags of destroyed apps."}
			}},
		{Key: "h", Label: "health", Help: "flk doctor: every host check", View: ViewHealth},
	}
	keys := "123456789"
	n := 0
	for _, p := range t.Problems {
		if cmd := rootStep(p.Hint); cmd != "" && n < len(keys) {
			acts = append(acts, Action{Key: keys[n : n+1], Label: "copy: " + cmd,
				Help: "needs root, so lazyflk doesn't run it: paste it in a shell (" + p.Label + ")",
				View: ViewCopy, Copy: cmd})
			n++
		}
	}
	return acts
}

var sudoRE = regexp.MustCompile(`sudo [^;,()]+`)

// rootStep is the sudo command in a hint, if any.
func rootStep(hint string) string {
	return strings.TrimRight(strings.TrimSpace(sudoRE.FindString(hint)), ".")
}

func plural(n int, word string) string {
	if n == 1 {
		return "1 " + word
	}
	return fmt.Sprintf("%d %ss", n, word)
}

// Run is an action that runs c as is (for providers: podman, sh...).
func Run(key, label, help string, confirm Confirm, typeName string, c Command) Action {
	return Action{Key: key, Label: label, Help: help, Confirm: confirm, TypeName: typeName, Long: true,
		build: func(map[string]string) Command { return c }}
}

// CopyOnly is an action that only copies a command (root steps).
func CopyOnly(key, label, help, cmd string) Action {
	return Action{Key: key, Label: label, Help: help, View: ViewCopy, Copy: cmd}
}

// FollowLogs is an action that follows c's output in the logs view.
func FollowLogs(key, help string, c Command) Action {
	return Action{Key: key, Label: "logs", Help: help, View: ViewLogs, Logs: &c}
}

// Custom is an action whose command is made from typed input (an app's
// own actions): make returns the command, or why it can't run.
func Custom(key, label, help string, needsInput bool, make func(input string) (Command, string)) Action {
	a := Action{Key: key, Label: label, Help: help, Confirm: Ask, Long: true,
		build: func(v map[string]string) Command { c, _ := make(v["input"]); return c },
		check: func(v map[string]string) string { _, why := make(v["input"]); return why }}
	if needsInput {
		a.Fields = []Field{{Name: "input", Label: "input", Required: true, Help: "goes where the command says {input}"}}
	}
	return a
}
