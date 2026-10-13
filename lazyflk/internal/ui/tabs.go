package ui

import (
	"context"
	"fmt"
	"sort"
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"

	"lazyflk/internal/flk"
	"lazyflk/internal/host"
)

// Detail tabs per selection (SPEC 5.1). Services and Images on the host
// wait for data flk doesn't give yet (SPEC 9, 10).
func tabNames(k nodeKind) []string {
	switch k {
	case kindApp:
		return []string{"Overview", "Logs", "Ports", "Volumes", "Releases", "Secrets", "Config"}
	case kindMachine:
		return []string{"Overview", "Logs", "Record"}
	case kindHost:
		return []string{"Health", "Ports", "Disk"}
	case kindVolume:
		return []string{"Overview", "Backups"}
	}
	return []string{"Overview"}
}

const logPreview = 200 // lines the Logs tab asks for

// source is a command whose output a tab shows, cached by its command line.
type source struct {
	cmd  string // as shown to the admin, and the cache key
	ttl  time.Duration
	load func(context.Context) (any, error)
}

// fetched is a source's latest result; val stays from the last success.
type fetched struct {
	val     any
	err     error
	at      time.Time
	loading bool
}

type fetchedMsg struct {
	key string
	val any
	err error
}

func flkSource[T any](args []string, ttl time.Duration, load func(context.Context) (T, error)) *source {
	return &source{cmd: flk.CommandLine(args...), ttl: ttl,
		load: func(ctx context.Context) (any, error) { return load(ctx) }}
}

// textSource shows a command's output as is.
func (m *Model) textSource(args []string, ttl time.Duration) *source {
	c := m.opt.Client
	return flkSource(args, ttl, func(ctx context.Context) (string, error) {
		out, err := c.Run(ctx, args...)
		return string(out), err
	})
}

func logArgs(app, id string) []string {
	args := []string{"-a", app, "logs"}
	if id != "" {
		args = append(args, "-i", id)
	}
	return append(args, "-n", fmt.Sprint(logPreview), "--no-tail")
}

// tabSource is what feeds a tab, or nil when the context data is enough.
func (m *Model) tabSource(n node, tab string) *source {
	c := m.opt.Client
	switch n.kind {
	case kindApp:
		app := m.apps[n.app].Name
		switch tab {
		case "Logs":
			return m.textSource(logArgs(app, ""), 5*time.Second)
		case "Releases":
			return flkSource([]string{"-a", app, "releases", "--json"}, 15*time.Second,
				func(ctx context.Context) ([]flk.Release, error) { return c.Releases(ctx, app) })
		case "Secrets":
			return flkSource([]string{"-a", app, "secrets", "list", "--json"}, 15*time.Second,
				func(ctx context.Context) ([]flk.Secret, error) { return c.Secrets(ctx, app) })
		case "Config":
			return m.textSource([]string{"-a", app, "config", "show"}, 15*time.Second)
		case "Volumes":
			if len(m.apps[n.app].Volumes) > 0 {
				return m.backupSource(app)
			}
		}
	case kindVolume:
		if tab == "Backups" {
			return m.backupSource(m.apps[n.app].Name)
		}
	case kindMachine:
		a := m.apps[n.app]
		id := a.Machines[n.machine].ID
		switch tab {
		case "Logs":
			return m.textSource(logArgs(a.Name, id), 5*time.Second)
		case "Record":
			return m.textSource([]string{"-a", a.Name, "machine", "status", id}, 5*time.Second)
		}
	case kindHost:
		switch tab {
		case "Health":
			return flkSource([]string{"doctor", "--json"}, 30*time.Second, c.Doctor)
		case "Ports":
			return flkSource([]string{"ports", "list", "--json"}, 5*time.Second, c.Ports)
		case "Disk":
			return m.diskSource()
		}
	}
	return nil
}

// backupSource lists an app's volume backups (flk volumes backups).
func (m *Model) backupSource(app string) *source {
	c := m.opt.Client
	return flkSource([]string{"-a", app, "volumes", "backups", "--json"}, 30*time.Second,
		func(ctx context.Context) ([]flk.Backup, error) { return c.Backups(ctx, app) })
}

// backups is an app's backups if loaded (nil if not), or why they can't be.
func (m *Model) backups(app string) ([]flk.Backup, string) {
	f := m.cache[m.backupSource(app).cmd]
	if f == nil {
		return nil, ""
	}
	if b, ok := f.val.([]flk.Backup); ok && b != nil {
		return b, ""
	}
	if f.err != nil {
		return nil, "can't list backups: " + firstLine(f.err.Error())
	}
	return nil, ""
}

// diskSource is df over flk's state dir and every volume's directory.
func (m *Model) diskSource() *source {
	if m.opt.Disk == nil || m.hc == nil {
		return nil
	}
	paths := m.hc.MountDirs
	if len(paths) == 0 && m.hc.Flk.StateDir != "" {
		paths = []string{m.hc.Flk.StateDir}
	}
	if len(paths) == 0 {
		return nil
	}
	disk := m.opt.Disk
	return &source{cmd: strings.Join(host.DFArgs(paths), " "), ttl: 30 * time.Second,
		load: func(ctx context.Context) (any, error) {
			ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
			defer cancel()
			return disk(ctx, paths)
		}}
}

// want starts loading a source unless it's fresh or already loading.
func (m *Model) want(src *source) tea.Cmd {
	if src == nil {
		return nil
	}
	f := m.cache[src.cmd]
	if f == nil {
		f = &fetched{}
		m.cache[src.cmd] = f
	}
	if f.loading || (!f.at.IsZero() && m.now().Sub(f.at) < src.ttl) {
		return nil
	}
	f.loading = true
	key, load := src.cmd, src.load
	return func() tea.Msg {
		v, err := load(context.Background())
		return fetchedMsg{key, v, err}
	}
}

func (m *Model) gotFetched(msg fetchedMsg) {
	f := m.cache[msg.key]
	if f == nil {
		return
	}
	f.loading, f.at, f.err = false, m.now(), msg.err
	if msg.err == nil {
		f.val = msg.val
	}
}

// tabBody renders a tab's lines, scrolled by the caller.
func (m *Model) tabBody(n node, tab string, w, h int) []string {
	src := m.tabSource(n, tab)
	if src == nil {
		if n.kind == kindHost && tab == "Disk" {
			return []string{styleDim.Render("disk usage needs flk's directories (loading…)")}
		}
		return m.contextTab(n, tab)
	}
	var out []string
	for i, l := range wrap("$ "+src.cmd, w) {
		if i > 0 {
			l = "  " + l
		}
		out = append(out, styleDim.Render(l))
	}
	f := m.cache[src.cmd]
	switch {
	case f == nil || (f.val == nil && f.err == nil):
		return append(out, "", styleDim.Render("loading…"))
	case f.err != nil:
		out = append(out, "")
		for _, l := range wrap(f.err.Error(), w) {
			out = append(out, styleBad.Render(l))
		}
		if f.val == nil {
			if tab == "Volumes" { // the volumes still show, without backups
				return append(append(out, ""), m.appVolumeLines(m.apps[n.app], nil)...)
			}
			return out
		}
		out = append(out, styleDim.Render("(showing the last good result)"))
	}
	out = append(out, "")
	switch v := f.val.(type) {
	case string:
		if tab == "Logs" {
			return append(out, m.logPreview(v, h-len(out))...)
		}
		return append(out, strings.Split(strings.TrimRight(cleanText(v), "\n"), "\n")...)
	case []flk.Release:
		return append(out, m.releaseLines(m.apps[n.app], v)...)
	case []flk.Secret:
		return append(out, secretLines(v)...)
	case []flk.Backup:
		a := m.apps[n.app]
		if n.kind == kindVolume {
			return append(out, backupLines(a.Volumes[n.volume], v)...)
		}
		return append(out, m.appVolumeLines(a, v)...)
	case flk.Doctor:
		return append(append(append(out, m.hostOverview()...), ""), doctorLines(v, w)...)
	case flk.PortsList:
		return append(out, m.hostPortLines(v)...)
	case []host.Disk:
		return append(out, diskLines(v)...)
	}
	return out
}

func cleanText(s string) string {
	lines := strings.Split(s, "\n")
	for i, l := range lines {
		lines[i] = cleanLog(l)
	}
	return strings.Join(lines, "\n")
}

// logPreview is the last h lines of `flk logs`, styled like the log view.
func (m *Model) logPreview(out string, h int) []string {
	var lines []string
	for _, l := range strings.Split(strings.TrimRight(out, "\n"), "\n") {
		lines = append(lines, classifyLog(flk.Line{Text: l}, func(id string) string { return id }).styled())
	}
	if len(lines) > h-1 {
		lines = lines[len(lines)-(h-1):]
	}
	return append(lines, styleDim.Render("l: follow, search, wrap (full screen)"))
}

// contextTab renders tabs fed by `flk context --all --json` alone.
func (m *Model) contextTab(n node, tab string) []string {
	switch {
	case n.kind == kindApp && tab == "Ports":
		return m.appPortLines(m.apps[n.app])
	case n.kind == kindApp && tab == "Volumes":
		return m.appVolumeLines(m.apps[n.app], nil)
	}
	_, lines := m.detail(n)
	return lines
}

func (m *Model) appPortLines(a flk.App) []string {
	var out []string
	for _, mc := range a.Machines {
		for _, p := range mc.Ports {
			out = append(out, fmt.Sprintf("%s/%d → %s", p.Proto, p.Port, forwardedTo(a.Ports, mc, p)),
				styleDim.Render(fmt.Sprintf("  %s %s:%d", or(mc.Name, mc.ID), mc.IP, p.InternalPort)))
		}
	}
	if len(out) == 0 {
		out = append(out, styleDim.Render("no [[services.ports]] in this app's config"))
	}
	ips := []string{}
	for _, mc := range a.Machines {
		if mc.IP != "" && mc.InternalPort != 0 {
			ips = append(ips, fmt.Sprintf("%s:%d", mc.IP, mc.InternalPort))
		}
	}
	if len(ips) > 0 {
		out = append(out, "", styleDim.Render("from this host: "+strings.Join(ips, " ")))
	}
	return out
}

// appVolumeLines lists an app's volumes, each with its latest backup
// when the backups are known.
func (m *Model) appVolumeLines(a flk.App, backups []flk.Backup) []string {
	if len(a.Volumes) == 0 {
		return []string{styleDim.Render("no volumes")}
	}
	var out []string
	for _, v := range a.Volumes {
		if len(out) > 0 {
			out = append(out, "")
		}
		out = append(out, styleTitle.Render(v.Name)+fmt.Sprintf(" %dGB", v.SizeGB)+externalNote(v, m.hc.Flk.StateDir))
		for _, l := range m.volumeOverview(a, v)[1:] {
			out = append(out, "  "+l)
		}
		if backups != nil {
			mine := volumeBackups(v, backups)
			if len(mine) == 0 {
				out = append(out, "  "+field("backup", styleWarn.Render("none yet")))
			} else {
				out = append(out, "  "+field("backup", fmt.Sprintf("%s (%s, %d kept)", when(mine[0].CreatedAt), checkText(mine[0]), len(mine))))
			}
		}
	}
	if backups != nil {
		out = append(out, "", styleDim.Render("enter on a volume: back up, restore, extend"))
	}
	return out
}

func volumeBackups(v flk.Volume, all []flk.Backup) []flk.Backup {
	var out []flk.Backup
	for _, b := range all {
		if b.VolumeID == v.ID || (b.VolumeID == "" && b.Volume == v.Name) {
			out = append(out, b)
		}
	}
	return out
}

func checkText(b flk.Backup) string {
	switch b.Check {
	case "clean":
		return styleOK.Render("checked clean")
	case "repaired":
		return styleWarn.Render("repaired")
	case "errors":
		return styleBad.Render("has errors")
	}
	return or(b.Check, "unchecked")
}

// backupLines lists one volume's backups, newest first.
func backupLines(v flk.Volume, all []flk.Backup) []string {
	mine := volumeBackups(v, all)
	if len(mine) == 0 {
		return []string{styleDim.Render("no backups of " + v.Name + " yet (enter: back up)")}
	}
	var out []string
	for i, b := range mine {
		if i > 0 {
			out = append(out, "")
		}
		how := "mode " + or(b.Mode, "?")
		if b.Release > 0 {
			how += fmt.Sprintf(" · release v%d", b.Release)
		}
		out = append(out, styleTitle.Render(b.File),
			fmt.Sprintf("  %s · %s used · %s", when(b.CreatedAt), host.Human(b.BytesUsed/1024), checkText(b)),
			styleDim.Render(fmt.Sprintf("  %s · took %.0fs", how, b.Seconds)))
	}
	out = append(out, "", styleDim.Render("restore: stop the machine first"))
	return out
}

func (m *Model) releaseLines(a flk.App, rels []flk.Release) []string {
	running := map[int][]string{}
	for _, mc := range a.Machines {
		running[mc.Release] = append(running[mc.Release], or(mc.Name, mc.ID))
	}
	current := 0
	if a.Release != nil {
		current = a.Release.Version
	}
	sorted := append([]flk.Release(nil), rels...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i].Version > sorted[j].Version })
	var out []string
	for _, r := range sorted {
		s := fmt.Sprintf("v%-3d %s  %s", r.Version, when(r.CreatedAt), or(r.Source, "?"))
		if r.Version == current {
			s = styleTitle.Render(s) + styleOK.Render("  current")
		}
		out = append(out, s)
		if names := running[r.Version]; len(names) > 0 {
			out = append(out, styleDim.Render("     running on "+strings.Join(names, ", ")))
		}
	}
	if len(out) == 0 {
		out = append(out, styleDim.Render("no releases yet: flk deploy"))
	}
	return out
}

func secretLines(secs []flk.Secret) []string {
	if len(secs) == 0 {
		return []string{styleDim.Render("no secrets (flk secrets set NAME=VALUE)")}
	}
	var out []string
	for _, s := range secs {
		out = append(out, fmt.Sprintf("%-24s %s", s.Name, styleDim.Render(s.Digest)))
	}
	return append(out, "", styleDim.Render("values are never shown; the digest changes when a value does"))
}

// doctorLines lists the checks; a failing one's fix is wrapped in full.
func doctorLines(d flk.Doctor, w int) []string {
	var out []string
	for _, c := range d.Checks {
		icon := styleOK.Render("✔")
		switch c.Status {
		case "fail":
			icon = styleBad.Render("✘")
		case "warn":
			icon = styleWarn.Render("!")
		}
		out = append(out, icon+" "+c.Label)
		if c.Hint != "" {
			for _, l := range wrap("→ "+c.Hint, w-2) {
				out = append(out, "  "+l)
			}
		}
	}
	return out
}

func (m *Model) hostPortLines(p flk.PortsList) []string {
	helper := styleOK.Render("installed")
	if !p.HelperInstalled {
		helper = styleWarn.Render("missing") + " (ports aren't forwarded: sudo setup-host.sh)"
	}
	out := []string{
		field("helper", helper),
		field("host", fmt.Sprintf("%s · ports from %d", or(p.HostAddress, "?"), p.MinPort)),
		"",
	}
	name := func(app, id string) string {
		for _, a := range m.apps {
			for _, mc := range a.Machines {
				if a.Name == app && mc.ID == id {
					return or(mc.Name, id)
				}
			}
		}
		return id
	}
	owner := func(x flk.Port) string {
		return styleDim.Render(fmt.Sprintf("  %s / %s %s:%d", x.App, name(x.App, x.Machine), x.IP, x.InternalPort))
	}
	for _, x := range p.Active {
		out = append(out, x.Key+" → "+x.Address, owner(x))
	}
	for _, x := range p.Waiting {
		out = append(out, x.Key+" "+styleWarn.Render("waiting: another machine has it"), owner(x))
	}
	for _, x := range p.Blocked {
		out = append(out, x.Key+" "+styleBad.Render("blocked: "+x.Blocked), owner(x))
	}
	if len(p.Active)+len(p.Waiting)+len(p.Blocked) == 0 {
		out = append(out, styleDim.Render("no ports forwarded"))
	}
	return out
}

func diskLines(disks []host.Disk) []string {
	var out []string
	for _, d := range disks {
		if len(out) > 0 {
			out = append(out, "")
		}
		pct := fmt.Sprintf("%3d%%", d.Percent)
		switch {
		case d.Percent >= host.AlarmPercent:
			pct = styleBad.Render(pct)
		case d.Percent >= host.WarnPercent:
			pct = styleWarn.Render(pct)
		}
		filled := min(max(d.Percent, 0), 100) / 10
		out = append(out,
			fmt.Sprintf("%s %s %s", pct, strings.Repeat("█", filled)+strings.Repeat("░", 10-filled), styleTitle.Render(d.Target)),
			fmt.Sprintf("     %s free of %s", host.Human(d.AvailKB), host.Human(d.SizeKB)))
		for _, p := range d.Paths {
			out = append(out, styleDim.Render("     holds "+p))
		}
	}
	return out
}

// diskWarnings are attention lines for disks past the warning threshold.
func (m *Model) diskWarnings() []string {
	src := m.diskSource()
	if src == nil || m.cache[src.cmd] == nil {
		return nil
	}
	disks, _ := m.cache[src.cmd].val.([]host.Disk)
	var out []string
	for _, d := range disks {
		if d.Percent >= host.WarnPercent {
			out = append(out, fmt.Sprintf("disk %s is %d%% full (%s free); it holds %s",
				d.Target, d.Percent, host.Human(d.AvailKB), strings.Join(d.Paths, ", ")))
		}
	}
	return out
}
