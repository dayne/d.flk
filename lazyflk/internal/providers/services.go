package providers

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"lazyflk/internal/actions"
)

// Services is flk's own systemd units, then the ones the admin pins
// (SPEC 10.3). State comes from `systemctl show`, logs from journalctl;
// both work as the user. Start, stop and restart need root, so they're
// copied, not run.
type Services struct {
	PinsFile string // one unit per line; "" or missing: DefaultPins
}

var flkUnits = []string{"flk-net.service", "flk-machines.service"}

// DefaultPins is what the reference host runs besides flk.
var DefaultPins = []string{"ssh.service", "snap.mosquitto.mosquitto.service", "chrony.service"}

const unitProps = "Id,Description,LoadState,ActiveState,SubState,UnitFileState,ActiveEnterTimestamp,StateChangeTimestamp,MainPID,Result,NRestarts"

// PinsPath is where pins live: ~/.config/lazyflk/pins.
func PinsPath() string {
	dir, err := os.UserConfigDir()
	if err != nil {
		return ""
	}
	return filepath.Join(dir, "lazyflk", "pins")
}

func (s Services) pins() ([]string, bool) {
	if s.PinsFile == "" {
		return DefaultPins, false
	}
	b, err := os.ReadFile(s.PinsFile)
	if err != nil {
		return DefaultPins, false
	}
	var out []string
	for _, l := range strings.Split(string(b), "\n") {
		l = strings.TrimSpace(l)
		if l == "" || strings.HasPrefix(l, "#") {
			continue
		}
		if !strings.Contains(l, ".") {
			l += ".service"
		}
		out = append(out, l)
	}
	return out, true
}

func (Services) Name() string { return "Services" }
func (s Services) Command() string {
	return "systemctl show --timestamp=utc -p ... UNIT... · journalctl -u UNIT"
}

func (s Services) Load(ctx context.Context, h Host, env Env) ([]Item, error) {
	pins, fromFile := s.pins()
	units := append(append([]string(nil), flkUnits...), pins...)
	args := append([]string{"show", "--timestamp=utc", "-p", unitProps}, units...)
	out, err := run(ctx, h, "systemctl", args...)
	if err != nil {
		return nil, err
	}
	journal := ""
	if g, err := run(ctx, h, "id", "-Gn"); err == nil && !canReadJournal(string(g)) {
		journal = "journalctl only shows your own messages: add yourself to the systemd-journal (or adm) group: sudo usermod -aG systemd-journal $USER"
	}
	pinNote := "pinned by default; edit " + or(s.PinsFile, "~/.config/lazyflk/pins") + " (one unit per line) to change"
	if fromFile {
		pinNote = "pinned in " + s.PinsFile
	}
	var items []Item
	for i, props := range parseShow(string(out)) {
		unit := props["Id"]
		if unit == "" && i < len(units) {
			unit = units[i]
		}
		isFlk := i < len(flkUnits)
		items = append(items, unitItem(unit, props, isFlk, pinNote, journal))
	}
	return items, nil
}

func canReadJournal(groups string) bool {
	for _, g := range strings.Fields(groups) {
		if g == "systemd-journal" || g == "adm" || g == "wheel" || g == "root" {
			return true
		}
	}
	return false
}

// parseShow splits `systemctl show` output into one map per unit.
func parseShow(out string) []map[string]string {
	var res []map[string]string
	for _, block := range strings.Split(strings.TrimSpace(out), "\n\n") {
		m := map[string]string{}
		for _, l := range strings.Split(block, "\n") {
			if k, v, ok := strings.Cut(l, "="); ok {
				m[k] = v
			}
		}
		res = append(res, m)
	}
	return res
}

func unitItem(unit string, p map[string]string, isFlk bool, pinNote, journal string) Item {
	name := strings.TrimSuffix(unit, ".service")
	it := Item{Key: "service/" + unit, Title: "service " + unit}
	active, sub := p["ActiveState"], p["SubState"]
	switch {
	case p["LoadState"] == "not-found":
		it.Label, it.State = "○ "+name+" (not here)", Off
		it.Lines = []string{field("state", "not installed on this host")}
		if !isFlk {
			it.Lines = append(it.Lines, "", pinNote)
		} else {
			it.Lines = append(it.Lines, "", "flk's boot units: sudo setup-host.sh --install-service")
		}
		return it
	case active == "failed":
		it.Label, it.State = "✘ "+name, Bad
		if !isFlk { // flk's own failed units are doctor warnings already
			it.Problems = append(it.Problems, fmt.Sprintf("service %s failed: journalctl -u %s -b, then sudo systemctl restart %s", unit, unit, unit))
		}
	case active == "active":
		it.Label = "● " + name
	default:
		it.Label, it.State = "○ "+name, Off
	}
	state := active
	if sub != "" {
		state += " (" + sub + ")"
	}
	it.Lines = []string{
		field("unit", unit),
		field("what", p["Description"]),
		field("state", state),
		field("enabled", or(p["UnitFileState"], "-")),
	}
	if t := p["StateChangeTimestamp"]; t != "" {
		it.Lines = append(it.Lines, field("since", t))
	}
	if pid := p["MainPID"]; pid != "" && pid != "0" {
		it.Lines = append(it.Lines, field("pid", pid))
	}
	if n := p["NRestarts"]; n != "" && n != "0" {
		it.Lines = append(it.Lines, field("restarts", n))
	}
	if r := p["Result"]; r != "" && r != "success" {
		it.Lines = append(it.Lines, field("result", r))
	}
	if isFlk {
		it.Lines = append(it.Lines, "", "one of flk's units (oneshot: healthy is active (exited))")
	} else {
		it.Lines = append(it.Lines, "", pinNote)
	}
	if journal != "" {
		it.Lines = append(it.Lines, "", journal)
	}
	logs := actions.Command{Program: "journalctl", Args: []string{"-u", unit, "-f", "-n", "200", "--no-pager", "-o", "short-iso"}}
	it.Logs = &logs
	it.Actions = []actions.Action{
		actions.FollowLogs("l", "follow its journal (journalctl -u "+unit+" -f)", logs),
		actions.CopyOnly("r", "copy: sudo systemctl restart "+unit, "needs root, so lazyflk copies it", "sudo systemctl restart "+unit),
		actions.CopyOnly("S", "copy: sudo systemctl stop "+unit, "needs root, so lazyflk copies it", "sudo systemctl stop "+unit),
		actions.CopyOnly("s", "copy: sudo systemctl start "+unit, "needs root, so lazyflk copies it", "sudo systemctl start "+unit),
	}
	return it
}

func or(s, fallback string) string {
	if s == "" {
		return fallback
	}
	return s
}
