package ui

import (
	"context"
	"fmt"
	"os"
	"path"
	"strings"
	"time"
	"unicode/utf8"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"

	"lazyflk/internal/actions"
	"lazyflk/internal/flk"
	"lazyflk/internal/host"
)

// filesView browses a volume, or a backup of it, with flk files (flk
// ef6f865): list directories, read text files, copy out. Read-only:
// writes need the machine stopped and stay on the command line.
type filesView struct {
	app, vol string
	backup   string // "" reads the live volume
	dir      string // the directory listed
	cursor   int
	top      int
	file     string // the file being read, "" when listing
	fileTop  int
}

// maxShown is the biggest file the view reads; bigger ones are copied out.
const maxShown = 1 << 20

func (m *Model) openFiles() tea.Cmd {
	n, ok := m.selected()
	if !ok || n.kind != kindVolume {
		return nil
	}
	a := m.apps[n.app]
	m.files = &filesView{app: a.Name, vol: a.Volumes[n.volume].Name, dir: "/"}
	return tea.Batch(m.want(m.lsSource()), m.want(m.backupSource(a.Name)))
}

func (m *Model) lsSource() *source {
	f, c := m.files, m.opt.Client
	app, vol, dir, b := f.app, f.vol, f.dir, f.backup
	return flkSource(flk.FilesArgs(app, "ls", vol, dir, b, "--json"), 10*time.Second,
		func(ctx context.Context) ([]flk.FileEntry, error) { return c.FilesLs(ctx, app, vol, dir, b) })
}

func (m *Model) catSource() *source {
	f := m.files
	return m.textSource(flk.FilesArgs(f.app, "cat", f.vol, f.file, f.backup), 10*time.Second)
}

// entries is the listed directory, or nil and why not (loading, an error).
func (m *Model) entries() ([]flk.FileEntry, string) {
	f := m.cache[m.lsSource().cmd]
	switch {
	case f == nil || (f.val == nil && f.err == nil):
		return nil, "loading…"
	case f.err != nil && f.val == nil:
		return nil, f.err.Error()
	}
	e, _ := f.val.([]flk.FileEntry)
	return e, ""
}

// fileVolume is the browsed volume, if the app still has it.
func (m *Model) fileVolume() (flk.App, flk.Volume, bool) {
	for _, a := range m.apps {
		for _, v := range a.Volumes {
			if a.Name == m.files.app && v.Name == m.files.vol {
				return a, v, true
			}
		}
	}
	return flk.App{}, flk.Volume{}, false
}

// sources are what can be read: the live volume, then its backups,
// newest first.
func (m *Model) fileSources() []string {
	out := []string{""}
	_, v, ok := m.fileVolume()
	if !ok {
		return out
	}
	b, _ := m.backups(m.files.app)
	for _, x := range volumeBackups(v, b) {
		out = append(out, x.File)
	}
	return out
}

func (m *Model) filesKey(msg tea.KeyPressMsg) tea.Cmd {
	f := m.files
	k := msg.String()
	page := max(m.height-9, 1)
	if f.file != "" {
		lines, _ := m.fileLines()
		switch k {
		case "esc", "q", "left", "h", "backspace":
			f.file = ""
		case "up", "k":
			f.fileTop--
		case "down", "j":
			f.fileTop++
		case "pgup", "ctrl+u", "ctrl+b":
			f.fileTop -= page
		case "pgdown", "ctrl+d", "ctrl+f", "space":
			f.fileTop += page
		case "g", "home":
			f.fileTop = 0
		case "G", "end":
			f.fileTop = len(lines)
		case "c":
			return m.copyOut(f.file)
		}
		f.fileTop = max(min(f.fileTop, len(lines)-page), 0)
		return nil
	}
	es, _ := m.entries()
	switch k {
	case "esc", "q":
		m.files = nil
	case "up", "k":
		f.cursor--
	case "down", "j":
		f.cursor++
	case "pgup", "ctrl+u", "ctrl+b":
		f.cursor -= page
	case "pgdown", "ctrl+d", "ctrl+f", "space":
		f.cursor += page
	case "g", "home":
		f.cursor = 0
	case "G", "end":
		f.cursor = len(es)
	case "enter", "right", "l":
		if f.cursor < len(es) {
			return m.openEntry(es[f.cursor])
		}
	case "left", "h", "backspace":
		if f.dir != "/" {
			from := path.Base(f.dir)
			f.dir, f.cursor, f.top = path.Dir(f.dir), 0, 0
			cmd := m.want(m.lsSource())
			if es, _ := m.entries(); es != nil {
				for i, e := range es {
					if e.Name == from {
						f.cursor = i
					}
				}
			}
			return cmd
		}
	case "b":
		srcs := m.fileSources()
		for i, s := range srcs {
			if s == f.backup {
				f.backup = srcs[(i+1)%len(srcs)]
				break
			}
		}
		return m.want(m.lsSource()) // same dir and place, in the other copy
	case "r":
		delete(m.cache, m.lsSource().cmd)
		return m.want(m.lsSource())
	case "c":
		p := f.dir
		if f.cursor < len(es) {
			p = path.Join(f.dir, es[f.cursor].Name)
		}
		return m.copyOut(p)
	}
	f.cursor = max(min(f.cursor, len(es)-1), 0)
	return nil
}

// openEntry goes into a directory or reads a file.
func (m *Model) openEntry(e flk.FileEntry) tea.Cmd {
	f := m.files
	p := path.Join(f.dir, e.Name)
	switch {
	case e.Type == "dir":
		f.dir, f.cursor, f.top = p, 0, 0
		return m.want(m.lsSource())
	case e.Type != "file":
		m.note = e.Name + " is a " + e.Type + ": flk files doesn't follow it (c copies it out)"
	case e.Size > maxShown:
		m.note = fmt.Sprintf("%s is %s, too big to show here: c copies it out", e.Name, sizeText(e.Size))
	default:
		f.file, f.fileTop = p, 0
		return m.want(m.catSource())
	}
	return nil
}

// copyOut opens the copy-out form for p, to the directory lazyflk
// started in.
func (m *Model) copyOut(p string) tea.Cmd {
	if m.opt.ReadOnly {
		m.note = "read-only: copying out is off (started with --read-only)"
		return nil
	}
	a, _, ok := m.fileVolume()
	if !ok {
		return nil
	}
	dest, err := os.Getwd()
	if err != nil {
		dest = "."
	}
	f := m.files
	return m.choose(f.app+" / "+f.vol, actions.CopyOut(a, f.vol, p, f.backup, strings.TrimRight(dest, "/")+"/"))
}

// fileLines is the open file's text, or nil and why it isn't shown.
func (m *Model) fileLines() ([]string, string) {
	f := m.cache[m.catSource().cmd]
	switch {
	case f == nil || (f.val == nil && f.err == nil):
		return nil, "loading…"
	case f.val == nil:
		return nil, f.err.Error()
	}
	s := f.val.(string)
	if strings.ContainsRune(s, 0) || !utf8.ValidString(s) {
		return nil, "a binary file: c copies it out"
	}
	return strings.Split(strings.TrimRight(cleanText(s), "\n"), "\n"), ""
}

func sizeText(b int64) string {
	if b < 1024 {
		return fmt.Sprintf("%dB", b)
	}
	return host.Human(b / 1024)
}

func (m *Model) filesScreen() string {
	f := m.files
	w, h := m.width, m.height
	inner, room := w-4, h-4
	src := "live"
	if f.backup != "" {
		src = "backup " + f.backup
	}
	title := "files ─ " + f.app + " / " + f.vol + " ─ " + src
	_, v, ok := m.fileVolume()
	inUse := ""
	if ok && f.backup == "" {
		for _, a := range m.apps {
			for _, mc := range a.Machines {
				if mc.ID == v.AttachedMachine && mc.Started() {
					inUse = "in use by " + or(mc.Name, mc.ID) + ": this is what's on disk now (b: read a backup)"
				}
			}
		}
	}
	var body []string
	var foot string
	if f.file != "" {
		body = append(body, styleTitle.Render(f.vol+":"+f.file))
		if inUse != "" {
			body = append(body, styleDim.Render(inUse))
		}
		body = append(body, "")
		lines, why := m.fileLines()
		if lines == nil {
			body = append(body, styleDim.Render(why))
		}
		page := room - len(body)
		for i := f.fileTop; i < len(lines) && len(body) < room; i++ {
			body = append(body, lines[i])
		}
		if len(lines) > page {
			title += fmt.Sprintf(" ─ %d%%", min(100, (f.fileTop+page)*100/len(lines)))
		}
		m.addWheel(1, h-3, func(d int) { f.fileTop = max(min(f.fileTop+d, len(lines)-page), 0) })
		foot = m.hints("↑↓ pgup/dn", "scroll", "c", "copy out", "esc", "back")
	} else {
		body = append(body, styleTitle.Render(f.vol+":"+f.dir))
		if inUse != "" {
			body = append(body, styleDim.Render(inUse))
		}
		body = append(body, "")
		es, why := m.entries()
		if es == nil {
			for _, l := range wrap(why, inner) {
				body = append(body, styleDim.Render(l))
			}
		} else if len(es) == 0 {
			body = append(body, styleDim.Render("empty"))
		}
		nameW := min(max(inner-47, 12), 48) // the icon and the other columns take 47
		if len(es) > 0 {
			body = append(body, styleDim.Render(fmt.Sprintf("  %-*s %8s  %4s  %-9s  %s", nameW, "name", "size", "mode", "owner", "modified")))
		}
		page := room - len(body)
		f.cursor = max(min(f.cursor, len(es)-1), 0)
		if f.cursor < f.top {
			f.top = f.cursor
		}
		if f.cursor >= f.top+page {
			f.top = f.cursor - page + 1
		}
		for i := f.top; i < len(es) && len(body) < room; i++ {
			e := es[i]
			name := e.Name
			switch e.Type {
			case "dir":
				name = "▸ " + name + "/"
			case "symlink":
				name = "↪ " + name
			case "other":
				name = "? " + name
			default:
				name = "  " + name
			}
			size := sizeText(e.Size)
			if e.Type == "dir" {
				size = ""
			}
			line := fmt.Sprintf("%s %8s  %4s  %-9s  %s", fit(name, nameW+2), size, e.Mode, fmt.Sprintf("%d:%d", e.UID, e.GID), when(e.MTime))
			if i == f.cursor {
				line = styleSelected.Render(fit(line, inner))
			} else if e.Type == "dir" {
				line = styleTitle.Render(line)
			}
			idx := i
			m.bodyZone(len(body), func() tea.Cmd {
				if m.files.cursor == idx {
					return m.openEntry(es[idx])
				}
				m.files.cursor = idx
				return nil
			})
			body = append(body, line)
		}
		m.addWheel(1, h-3, func(d int) { f.cursor = max(min(f.cursor+d, len(es)-1), 0) })
		foot = m.hints("↑↓", "move", "enter", "open", "←", "up", "b", "live/backups", "c", "copy out", "r", "refresh", "esc", "close")
	}
	if m.note != "" {
		foot = styleWarn.Render(m.note)
	}
	for len(body) < room {
		body = append(body, "")
	}
	m.screenZones(m.footPairs)
	return strings.Join(box(ansi.Truncate(title, w-6, "…"), body, foot, w), "\n")
}
