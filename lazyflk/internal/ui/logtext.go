package ui

import (
	"path/filepath"
	"regexp"
	"strings"

	"github.com/charmbracelet/x/ansi"

	"lazyflk/internal/flk"
)

type logKind int

const (
	logText   logKind = iota
	logBanner         // flk's own "--- flk: ..." lines and log rotation
	logHeader         // tail's "==> FILE <==" when following several machines
	logError          // anything else on stderr
)

type logLine struct {
	text  string
	lower string // for case-insensitive search
	kind  logKind
}

var tailHeader = regexp.MustCompile(`^==> (.*) <==$`)

// cleanLog makes console output safe to draw: the serial console ends
// lines with \r\r\n, progress bars redraw with \r, and apps print their
// own colors and control codes. After a \r the last text written wins,
// as on a terminal.
func cleanLog(s string) string {
	s = ansi.Strip(s)
	if strings.Contains(s, "\r") {
		parts := strings.Split(s, "\r")
		s = ""
		for i := len(parts) - 1; i >= 0 && s == ""; i-- {
			s = parts[i]
		}
	}
	s = strings.ReplaceAll(s, "\t", "    ")
	return strings.Map(func(r rune) rune {
		if r < 0x20 || r == 0x7f {
			return -1
		}
		return r
	}, s)
}

// classifyLog turns one line of `flk logs` output into what the log view
// shows. name maps a machine ID to its display name.
func classifyLog(l flk.Line, name func(id string) string) logLine {
	text := cleanLog(l.Text)
	kind := logText
	switch {
	case l.Stderr && (strings.Contains(text, "has been replaced") || strings.Contains(text, "file truncated")):
		text, kind = "── log rotated (older lines are in console.log.1) ──", logBanner
	case l.Stderr:
		kind = logError
	case strings.HasPrefix(text, "--- flk:"):
		kind = logBanner
	default:
		if m := tailHeader.FindStringSubmatch(text); m != nil {
			// .../apps/APP/machines/ID/console.log
			text, kind = "── "+name(filepath.Base(filepath.Dir(m[1])))+" ──", logHeader
		}
	}
	return logLine{text: text, lower: strings.ToLower(text), kind: kind}
}

func (l logLine) styled() string {
	switch l.kind {
	case logBanner:
		return styleWarn.Render(l.text)
	case logHeader:
		return styleTitle.Render(l.text)
	case logError:
		return styleBad.Render(l.text)
	}
	return l.text
}

// highlight marks every case-insensitive occurrence of q in plain text.
func highlight(text, q string) string {
	if q == "" {
		return text
	}
	lower, ql := strings.ToLower(text), strings.ToLower(q)
	var b strings.Builder
	for {
		i := strings.Index(lower, ql)
		if i < 0 || len(lower) != len(text) { // lowercasing changed byte offsets: skip
			b.WriteString(text)
			return b.String()
		}
		b.WriteString(text[:i])
		b.WriteString(styleMatch.Render(text[i : i+len(ql)]))
		text, lower = text[i+len(ql):], lower[i+len(ql):]
	}
}
