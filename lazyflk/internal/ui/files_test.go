package ui

import (
	"os"
	"strings"
	"testing"
)

// The volume menu's browse files (flk files, flk ef6f865): directories,
// text files, backups, copy out. The fake serves one test volume's tree
// for any volume.
func TestFilesView(t *testing.T) {
	for _, size := range [][2]int{{80, 24}, {160, 48}} {
		m := demoModel(t, size[0], size[1])
		goTo(m, kindVolume)
		press(m, "enter", "f")
		if m.files == nil {
			t.Fatalf("not open:\n%s", screen(m))
		}
		s := screen(m)
		for _, want := range []string{"files ─ minecraft-flk / world ─ live", "world:/", "▸ logs/", "▸ world/", "↪ current.log", "server.properties", "1000:1000", "in use by mellow-aurora-7882"} {
			if !strings.Contains(s, want) {
				t.Errorf("%dx%d: no %q in\n%s", size[0], size[1], want, s)
			}
		}
		snap(t, m, "files")

		press(m, "down") // logs
		press(m, "enter")
		if m.files.dir != "/logs" || !strings.Contains(screen(m), "latest.log") {
			t.Fatalf("into logs:\n%s", screen(m))
		}
		press(m, "enter")
		if s := screen(m); m.files.file != "/logs/latest.log" || !strings.Contains(s, "line 3") {
			t.Fatalf("read:\n%s", s)
		}
		snap(t, m, "files-read")
		press(m, "esc", "left")
		if m.files.dir != "/" || m.files.cursor != 1 {
			t.Errorf("back up to / on logs: %q %d", m.files.dir, m.files.cursor)
		}
		press(m, "b")
		if m.files.backup == "" || !strings.Contains(screen(m), "backup "+m.files.backup) || strings.Contains(screen(m), "in use by") {
			t.Errorf("backup:\n%s", screen(m))
		}
		press(m, "c")
		wd, _ := os.Getwd()
		if m.form == nil || m.form.act.Command(m.form.vals).Line() != "flk -a minecraft-flk files cp world:/logs "+wd+"/ --backup "+m.files.backup {
			t.Errorf("copy out:\n%s", screen(m))
		}
		press(m, "esc", "esc")
		if m.files != nil {
			t.Error("esc closes it")
		}
	}
}

// Symlinks, big files and binary files aren't shown, with a reason.
func TestFilesNotShown(t *testing.T) {
	m := demoModel(t, 120, 40)
	goTo(m, kindVolume)
	press(m, "enter", "f", "enter") // current.log, a symlink
	if m.files.file != "" || !strings.Contains(screen(m), "is a symlink") {
		t.Errorf("symlink:\n%s", screen(m))
	}
	if !strings.Contains(sizeText(2<<20), "M") || sizeText(21) != "21B" {
		t.Error(sizeText(2<<20), sizeText(21))
	}
}
