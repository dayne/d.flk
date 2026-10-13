package host

import (
	"io/fs"
	"reflect"
	"testing"

	"lazyflk/fixtures"
)

func TestParseDFFixture(t *testing.T) {
	out, err := fs.ReadFile(fixtures.FS, "df.txt")
	if err != nil {
		t.Fatal(err)
	}
	paths := []string{"/home/dayne/.local/share/flk", "/data/minecraft/flk", "/data/vintagestory/flk"}
	disks, err := ParseDF(string(out), paths)
	if err != nil {
		t.Fatal(err)
	}
	if len(disks) != 3 || disks[0].Target != "/" || disks[1].Target != "/data/minecraft" ||
		disks[1].Percent != 66 || disks[1].SizeKB != 102626232 || !reflect.DeepEqual(disks[1].Paths, paths[1:2]) ||
		!reflect.DeepEqual(disks[2].Paths, paths[2:]) {
		t.Errorf("%+v", disks)
	}
}

func TestParseDFGroupsAndSpaces(t *testing.T) {
	out := "Mounted on 1K-blocks Used Avail Use%\n/ 100 90 10 90%\n/mnt/my disk 2048 1024 1024 50%\n/ 100 90 10 90%\n"
	disks, err := ParseDF(out, []string{"/a", "/mnt/my disk/x", "/b"})
	if err != nil {
		t.Fatal(err)
	}
	want := []Disk{
		{Target: "/", SizeKB: 100, UsedKB: 90, AvailKB: 10, Percent: 90, Paths: []string{"/a", "/b"}},
		{Target: "/mnt/my disk", SizeKB: 2048, UsedKB: 1024, AvailKB: 1024, Percent: 50, Paths: []string{"/mnt/my disk/x"}},
	}
	if !reflect.DeepEqual(disks, want) {
		t.Errorf("got %+v", disks)
	}
	if _, err := ParseDF("Mounted on\n/ x y z 1%\n", nil); err == nil {
		t.Error("bad numbers should fail")
	}
}

func TestHuman(t *testing.T) {
	for kb, want := range map[int64]string{512: "512K", 2048: "2.0M", 102626232: "98G", 33216356: "32G", 5 << 30: "5.0T"} {
		if got := Human(kb); got != want {
			t.Errorf("Human(%d) = %s, want %s", kb, got, want)
		}
	}
}
