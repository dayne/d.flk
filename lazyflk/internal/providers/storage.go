package providers

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"lazyflk/internal/actions"
	"lazyflk/internal/host"
)

// Storage is every filesystem holding flk's data, with the
// devices under it from lsblk: the disk, partition and logical volume,
// and room the volume group hasn't handed out yet. Read-only; growing a
// volume is a root step to copy.
type Storage struct{}

const lsblkCols = "NAME,PATH,TYPE,SIZE,FSTYPE,FSSIZE,FSAVAIL,MOUNTPOINTS,MODEL"

type blockDev struct {
	Name        string     `json:"name"`
	Path        string     `json:"path"`
	Type        string     `json:"type"` // disk, part, lvm, crypt...
	Size        int64      `json:"size"`
	FSType      string     `json:"fstype"`
	MountPoints []string   `json:"mountpoints"`
	Model       string     `json:"model"`
	Children    []blockDev `json:"children"`
}

func (Storage) Name() string { return "Storage" }
func (Storage) Command() string {
	return "df -k MOUNT_DIRS · lsblk -e7 -b --json"
}

func (Storage) Load(ctx context.Context, h Host, env Env) ([]Item, error) {
	paths := append([]string(nil), env.MountDirs...)
	if len(paths) == 0 && env.StateDir != "" {
		paths = []string{env.StateDir}
	}
	if env.BackupDir != "" {
		paths = append(paths, env.BackupDir)
	}
	out, err := run(ctx, h, "df", host.DFArgs(paths)[1:]...)
	if err != nil {
		return nil, err
	}
	disks, err := host.ParseDF(string(out), paths)
	if err != nil {
		return nil, err
	}
	var tree struct {
		Devices []blockDev `json:"blockdevices"`
	}
	if b, err := run(ctx, h, "lsblk", "-e7", "-b", "--json", "-o", lsblkCols); err == nil {
		json.Unmarshal(b, &tree)
	}
	var items []Item
	for _, d := range disks {
		it := Item{Key: "storage/" + d.Target, Title: "filesystem " + d.Target,
			Label: fmt.Sprintf("%s %d%%", d.Target, d.Percent)}
		switch {
		case d.Percent >= host.AlarmPercent:
			it.State = Bad
		case d.Percent >= host.WarnPercent:
			it.State = Warn
		}
		it.Lines = []string{
			field("used", fmt.Sprintf("%d%% · %s free of %s", d.Percent, host.Human(d.AvailKB), host.Human(d.SizeKB))),
		}
		for i, p := range d.Paths {
			label := ""
			if i == 0 {
				label = "holds"
			}
			if p == env.BackupDir {
				p += " (backups)"
			}
			it.Lines = append(it.Lines, field(label, p))
		}
		if chain := findMount(tree.Devices, d.Target, nil); chain != nil {
			it.Lines = append(it.Lines, "", "devices, from the filesystem down:")
			for i := len(chain) - 1; i >= 0; i-- {
				b := chain[i]
				if strings.HasSuffix(b.Name, "-real") {
					continue // LVM's layer under a snapshotted volume
				}
				s := fmt.Sprintf("  %s  %s, %s", b.Path, b.Type, human(b.Size))
				if b.FSType != "" {
					s += ", " + b.FSType
				}
				if b.Model != "" {
					s += " · " + b.Model
				}
				it.Lines = append(it.Lines, s)
			}
			lv := chain[len(chain)-1]
			var pv *blockDev
			for i := range chain {
				if chain[i].FSType == "LVM2_member" {
					pv = &chain[i]
				}
			}
			// an LVM snapshot's origin sits on NAME-real, with the snapshot next to it
			for _, b := range chain {
				if !strings.HasSuffix(b.Name, "-real") {
					continue
				}
				for _, snap := range b.Children {
					if snap.Name == lv.Name {
						continue
					}
					cow := int64(0)
					if pv != nil {
						for _, c := range pv.Children {
							if c.Name == snap.Name+"-cow" {
								cow = c.Size
							}
						}
					}
					it.Lines = append(it.Lines, "",
						fmt.Sprintf("snapshot %s (%s copy-on-write space)", snap.Path, human(cow)),
						"  a snapshot slows writes and stops working once its space fills;",
						"  remove it when it's no longer needed (sudo lvremove "+snap.Path+")")
				}
			}
			if lv.Type == "lvm" && pv != nil {
				var used int64
				for _, c := range pv.Children {
					used += c.Size
				}
				if free := pv.Size - used; free > 1<<30 {
					grow := fmt.Sprintf("sudo lvextend -r -L +10G %s", lv.Path)
					it.Lines = append(it.Lines, "",
						fmt.Sprintf("%s of %s isn't in any logical volume yet: room to grow %s", human(free), pv.Path, d.Target),
						"  (e.g. "+grow+")")
					it.Actions = append(it.Actions, actions.CopyOnly("g", "copy: "+grow,
						"grows the logical volume and its filesystem by 10G; needs root, so it's copied, not run", grow))
				}
			}
		}
		items = append(items, it)
	}
	return items, nil
}

// findMount is the chain of devices from a disk down to the one mounted
// at target.
func findMount(devs []blockDev, target string, above []blockDev) []blockDev {
	for _, d := range devs {
		chain := append(append([]blockDev(nil), above...), d)
		for _, mp := range d.MountPoints {
			if mp == target {
				return chain
			}
		}
		if c := findMount(d.Children, target, chain); c != nil {
			return c
		}
	}
	return nil
}

func human(b int64) string {
	if b <= 0 {
		return "0"
	}
	return strings.TrimSpace(host.Human(b / 1024))
}
