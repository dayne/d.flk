package ui

import (
	"context"
	"fmt"
	"sort"
	"strings"
	"time"

	"lazyflk/internal/flk"
	"lazyflk/internal/host"
)

// M4: host extras from flk's G4–G10. Each degrades on an older flk: the
// data is missing, and the tab says which flk change brings it.

func (m *Model) doctorSource() *source {
	return flkSource([]string{"doctor", "--json"}, 30*time.Second, m.opt.Client.Doctor)
}

func (m *Model) statsSource() *source {
	return flkSource([]string{"machine", "stats", "--all", "--json"}, 5*time.Second, m.opt.Client.Stats)
}

func (m *Model) diskUseSource() *source {
	return flkSource([]string{"disk", "--json"}, 30*time.Second, m.opt.Client.DiskUse)
}

func (m *Model) imagesSource() *source {
	return flkSource([]string{"images", "--json"}, 30*time.Second, m.opt.Client.Images)
}

// quick reports whether polling can skip the host checks (G5): flk said
// it has a schema, which came with --no-host.
func (m *Model) quick() bool { return m.hc != nil && m.hc.Schema >= 1 }

// loadContext is the poll: the full context first, then (on a flk with
// G5) the quick one, with host health from doctor every 30s.
func (m *Model) loadContext(c *flk.Client, quick bool) func(context.Context) (flk.HostContext, bool, error) {
	return func(ctx context.Context) (flk.HostContext, bool, error) {
		if quick {
			hc, err := c.QuickContext(ctx)
			return hc, true, err
		}
		hc, err := c.HostContext(ctx)
		return hc, false, err
	}
}

// withHost fills a quick context's host part: from doctor if it has
// loaded, else from the last full one. flk's own rule for the host's
// next_steps is "fix:"/"optional:" LABEL -> HINT, first.
func (m *Model) withHost(hc flk.HostContext) flk.HostContext {
	lan := hc.Host.LanIP
	if m.hc != nil {
		hc.Host = m.hc.Host
	}
	hc.Host.LanIP = lan
	var hostSteps []string
	if f := m.cache[m.doctorSource().cmd]; f != nil {
		if d, ok := f.val.(flk.Doctor); ok {
			hc.Host = hostFromDoctor(d, lan)
		}
	}
	for _, p := range hc.Host.Problems {
		kind := "optional"
		if p.Status == "fail" {
			kind = "fix"
		}
		hostSteps = append(hostSteps, fmt.Sprintf("%s: %s -> %s", kind, p.Label, p.Hint))
	}
	hc.NextSteps = append(hostSteps, hc.NextSteps...)
	return hc
}

func hostFromDoctor(d flk.Doctor, lan string) flk.Host {
	h := flk.Host{OK: true, LanIP: lan, Services: d.Services}
	for _, c := range d.Checks {
		if c.Status == "fail" {
			h.OK = false
		}
		if c.Status != "pass" {
			h.Problems = append(h.Problems, c)
		}
		if strings.HasPrefix(c.Label, "boot service (") {
			h.BootService = true
		}
	}
	return h
}

// schemaWarning is an attention line when flk's JSON is newer than what
// this lazyflk understands (G6).
func (m *Model) schemaWarning() string {
	if m.hc == nil || m.hc.Schema <= flk.Schema {
		return ""
	}
	return fmt.Sprintf("flk's JSON is schema %d, this lazyflk knows %d: some fields may be missing or wrong; update lazyflk",
		m.hc.Schema, flk.Schema)
}

// stats is the live numbers of a machine, if loaded (G4).
func (m *Model) stats(id string) (flk.MachineStats, bool) {
	if f := m.cache[m.statsSource().cmd]; f != nil {
		all, _ := f.val.([]flk.MachineStats)
		for _, s := range all {
			if s.ID == id {
				return s, true
			}
		}
	}
	return flk.MachineStats{}, false
}

func uptime(s int) string {
	d := time.Duration(s) * time.Second
	switch {
	case d >= 48*time.Hour:
		return fmt.Sprintf("%dd %dh", int(d.Hours())/24, int(d.Hours())%24)
	case d >= time.Hour:
		return fmt.Sprintf("%dh %dm", int(d.Hours()), int(d.Minutes())%60)
	}
	return fmt.Sprintf("%dm", int(d.Minutes()))
}

// liveLines are a machine's CPU, memory and uptime for its Overview.
func (m *Model) liveLines(mc flk.Machine) []string {
	s, ok := m.stats(mc.ID)
	switch {
	case !ok && m.cache[m.statsSource().cmd] != nil && m.cache[m.statsSource().cmd].err != nil:
		return []string{field("live", styleDim.Render("no numbers: flk machine stats failed (needs flk with G4)"))}
	case !ok:
		return nil
	case s.CPUPercent == nil:
		return []string{field("live", styleDim.Render("not running"))}
	}
	out := []string{field("cpu", fmt.Sprintf("%.0f%% %s", *s.CPUPercent,
		styleDim.Render(fmt.Sprintf("(100%% = one host CPU; it has %d)", s.CPUs))))}
	if s.RSSMB != nil {
		out = append(out, field("memory", fmt.Sprintf("%dMB used of %dMB", *s.RSSMB, s.MemoryMB)))
	}
	if s.UptimeS != nil {
		out = append(out, field("up", uptime(*s.UptimeS)))
	}
	if s.PID != nil {
		out = append(out, field("pid", fmt.Sprint(*s.PID)+styleDim.Render(" (firecracker)")))
	}
	return out
}

// liveShort is the numbers on one line, for the app's Overview.
func (m *Model) liveShort(id string) string {
	s, ok := m.stats(id)
	if !ok || s.CPUPercent == nil {
		return ""
	}
	out := fmt.Sprintf(" · cpu %.0f%%", *s.CPUPercent)
	if s.RSSMB != nil {
		out += fmt.Sprintf(" · %dMB used", *s.RSSMB)
	}
	if s.UptimeS != nil {
		out += " · up " + uptime(*s.UptimeS)
	}
	return out
}

// unitAbout says what each of flk's units does.
var unitAbout = map[string]string{
	"flk-net.service":      "at boot: the bridge, NAT and port forwarding",
	"flk-machines.service": "at boot: flk resume; at shutdown: stops machines gracefully",
}

// serviceLines is the host Services tab (G9).
func serviceLines(svcs []flk.Service, w int) []string {
	if svcs == nil {
		return []string{styleDim.Render("this flk doesn't report its units (needs flk with G9);"),
			styleDim.Render("the boot service check is on the Health tab")}
	}
	var out []string
	for _, s := range svcs {
		icon, state := styleOK.Render("✔"), s.Active
		if s.Sub != "" {
			state += " (" + s.Sub + ")"
		}
		switch {
		case !s.Installed:
			icon, state = styleWarn.Render("!"), "not installed: sudo setup-host.sh --install-service"
		case s.Active == "failed":
			icon = styleBad.Render("✘")
		case s.Active != "active":
			icon = styleWarn.Render("!")
		}
		if len(out) > 0 {
			out = append(out, "")
		}
		out = append(out, icon+" "+styleTitle.Render(s.Unit)+"  "+state)
		if s.Installed {
			enabled := "enabled"
			if s.Enabled != nil && !*s.Enabled {
				enabled = styleWarn.Render("disabled") + " (won't run at boot)"
			}
			detail := enabled
			if s.Since != "" {
				detail += " · since " + when(s.Since)
			}
			if s.Result != "" && s.Result != "success" {
				detail += " · result " + styleBad.Render(s.Result)
			}
			out = append(out, "  "+detail)
		}
		if a := unitAbout[s.Unit]; a != "" {
			out = append(out, styleDim.Render("  "+a))
		}
		if s.Active == "failed" {
			for _, l := range wrap("why: journalctl -u "+s.Unit+" -b; then sudo systemctl restart "+s.Unit, w-2) {
				out = append(out, "  "+styleWarn.Render(l))
			}
		}
	}
	return append(out, "", styleDim.Render("oneshot units: healthy is active (exited)"))
}

func human(b int64) string { return host.Human(b / 1024) }

// imageLines is the host Images tab (G10): by app, newest first; sizes
// summed once per image ID, since two tags can share one.
func imageLines(imgs []flk.Image) []string {
	if len(imgs) == 0 {
		return []string{styleDim.Render("no images")}
	}
	byApp := map[string][]flk.Image{}
	var apps []string
	seen := map[string]bool{}
	var total, orphan int64
	for _, im := range imgs {
		if _, ok := byApp[im.App]; !ok {
			apps = append(apps, im.App)
		}
		byApp[im.App] = append(byApp[im.App], im)
		if !seen[im.ID] {
			seen[im.ID] = true
			total += im.SizeBytes
			if im.Orphan {
				orphan += im.SizeBytes
			}
		}
	}
	sort.SliceStable(apps, func(i, j int) bool {
		oi, oj := byApp[apps[i]][0].Orphan, byApp[apps[j]][0].Orphan
		if oi != oj {
			return !oi
		}
		return apps[i] < apps[j]
	})
	var out []string
	for _, a := range apps {
		if len(out) > 0 {
			out = append(out, "")
		}
		head := styleTitle.Render(or(a, "?"))
		if byApp[a][0].Orphan {
			head += styleWarn.Render("  app gone")
		}
		out = append(out, head)
		firstTag := map[string]string{} // image ID → the first (newest) tag shown with it
		for _, im := range byApp[a] {
			if _, ok := firstTag[im.ID]; !ok {
				firstTag[im.ID] = im.Tag
			}
		}
		for _, im := range byApp[a] {
			var tags []string
			switch {
			case im.Running:
				tags = append(tags, styleOK.Render("running"))
			case im.InUse:
				tags = append(tags, "in use")
			}
			if im.Current {
				tags = append(tags, "current")
			}
			if t := firstTag[im.ID]; t != im.Tag {
				tags = append(tags, styleDim.Render("same image as "+t))
			} else if len(tags) == 0 && !im.Orphan {
				tags = append(tags, styleDim.Render("older release"))
			}
			out = append(out, fmt.Sprintf("  %-4s %6s  %s", im.Tag, human(im.SizeBytes), strings.Join(tags, " · ")),
				styleDim.Render("              built "+when(im.CreatedAt)+" · "+im.ID))
		}
	}
	out = append(out, "", fmt.Sprintf("%s in %s", human(total), plural(len(seen), "image")))
	if orphan > 0 {
		out = append(out, styleWarn.Render(fmt.Sprintf("%s belong to apps that are gone: prune them (host menu: P, flk apps prune)", human(orphan))))
	}
	return out
}

// diskUseLines is what flk keeps where (G8), under the df view.
func diskUseLines(du flk.DiskUse) []string {
	sz := func(s flk.Size) string {
		if s.Bytes == 0 && s.Apparent == 0 {
			return "-"
		}
		return human(s.Bytes)
	}
	nameW := 4
	for _, a := range du.Apps {
		nameW = max(nameW, len(a.App))
	}
	row := func(name string, cells ...string) string {
		s := fmt.Sprintf("%-*s", nameW, name)
		for _, c := range cells {
			s += fmt.Sprintf(" %8s", c)
		}
		return s
	}
	out := []string{styleTitle.Render("What flk uses") + styleDim.Render("  (allocated; sparse files count what's written)"),
		field("state", fmt.Sprintf("%s in %s", human(du.StateDir.Bytes), du.StateDir.Path)),
		"",
		styleDim.Render(row("app", "images", "rootfs", "volumes", "logs", "external")),
	}
	for _, a := range du.Apps {
		out = append(out, row(a.App, sz(a.Images), sz(a.Rootfs), sz(a.Volumes), sz(a.Logs), sz(a.ExternalVolumes)))
	}
	t := du.Totals
	out = append(out, styleDim.Render(row("all", sz(t.Images), sz(t.Rootfs), sz(t.Volumes), sz(t.Logs), sz(t.ExternalVolumes))))
	if b := du.Backups; b != nil {
		out = append(out, "", field("backups", fmt.Sprintf("%s in %s", human(b.Bytes), b.Dir)))
		var names []string
		for n := range b.Apps {
			names = append(names, n)
		}
		sort.Strings(names)
		for _, n := range names {
			out = append(out, field("", fmt.Sprintf("%s %s", fit(n, nameW), human(b.Apps[n].Bytes))))
		}
	}
	return append(out, "", styleDim.Render("images: release rootfs · rootfs: each machine's copy · external: volumes outside the state dir"))
}
