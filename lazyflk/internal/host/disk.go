// Package host reads the few host facts flk doesn't report itself (SPEC 6):
// free space where flk keeps its state and volumes.
package host

import (
	"context"
	"fmt"
	"os/exec"
	"strconv"
	"strings"
)

// Disk is one filesystem and the flk directories that live on it.
type Disk struct {
	Target  string // mount point
	SizeKB  int64  // 1K blocks
	UsedKB  int64
	AvailKB int64
	Percent int      // df's Use%
	Paths   []string // the requested directories on this filesystem
}

// Thresholds from SPEC 10: warn at 85% full, alarm at 95%.
const (
	WarnPercent  = 85
	AlarmPercent = 95
)

// DFArgs is the df command for paths, as run and as shown to the admin.
func DFArgs(paths []string) []string {
	return append([]string{"df", "-k", "--output=target,size,used,avail,pcent"}, paths...)
}

// DF runs df for paths; directories that share a filesystem are grouped.
func DF(ctx context.Context, paths []string) ([]Disk, error) {
	args := DFArgs(paths)
	out, err := exec.CommandContext(ctx, args[0], args[1:]...).Output()
	if err != nil {
		if ee, ok := err.(*exec.ExitError); ok && len(ee.Stderr) > 0 {
			return nil, fmt.Errorf("%s", strings.TrimSpace(string(ee.Stderr)))
		}
		return nil, err
	}
	return ParseDF(string(out), paths)
}

// ParseDF reads df's output: a header, then one row per requested path, in
// order.
func ParseDF(out string, paths []string) ([]Disk, error) {
	lines := strings.Split(strings.TrimSpace(out), "\n")
	if len(lines) < 2 {
		return nil, fmt.Errorf("df printed nothing")
	}
	var disks []Disk
	byTarget := map[string]int{}
	for i, line := range lines[1:] {
		f := strings.Fields(line)
		if len(f) < 5 {
			return nil, fmt.Errorf("can't read df line %q", line)
		}
		// the mount point may contain spaces: the last four fields are numbers
		n := len(f)
		d := Disk{Target: strings.Join(f[:n-4], " ")}
		var errs [4]error
		d.SizeKB, errs[0] = strconv.ParseInt(f[n-4], 10, 64)
		d.UsedKB, errs[1] = strconv.ParseInt(f[n-3], 10, 64)
		d.AvailKB, errs[2] = strconv.ParseInt(f[n-2], 10, 64)
		d.Percent, errs[3] = strconv.Atoi(strings.TrimSuffix(f[n-1], "%"))
		for _, err := range errs {
			if err != nil {
				return nil, fmt.Errorf("can't read df line %q", line)
			}
		}
		j, seen := byTarget[d.Target]
		if !seen {
			j = len(disks)
			byTarget[d.Target] = j
			disks = append(disks, d)
		}
		if i < len(paths) {
			disks[j].Paths = append(disks[j].Paths, paths[i])
		}
	}
	return disks, nil
}

// Human formats a size in 1K blocks the way df -h does.
func Human(kb int64) string {
	v := float64(kb)
	for _, unit := range []string{"K", "M", "G", "T"} {
		if v < 1024 || unit == "T" {
			if v < 10 && unit != "K" {
				return fmt.Sprintf("%.1f%s", v, unit)
			}
			return fmt.Sprintf("%.0f%s", v, unit)
		}
		v /= 1024
	}
	return ""
}
