package providers

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"lazyflk/internal/actions"
)

// Podman is the containers and images podman keeps next to flk's: test
// containers left running, build containers an interrupted build left
// behind, and images no flk release uses. flk's own images (flk.local/*)
// are the host Images tab's.
type Podman struct {
	Now func() time.Time
}

type podmanContainer struct {
	ID        string   `json:"Id"`
	Names     []string `json:"Names"`
	Image     string   `json:"Image"`
	State     string   `json:"State"` // running, exited, created, storage (a build's)
	Status    string   `json:"Status"`
	Command   []string `json:"Command"`
	StartedAt int64    `json:"StartedAt"`
	Created   int64    `json:"Created"`
	ExitCode  int      `json:"ExitCode"`
}

type podmanImage struct {
	ID         string   `json:"Id"`
	Names      []string `json:"Names"`
	Size       int64    `json:"Size"`
	Containers int      `json:"Containers"`
	CreatedAt  string   `json:"CreatedAt"`
	Dangling   bool     `json:"Dangling"`
}

func (Podman) Name() string { return "Podman" }
func (Podman) Command() string {
	return "podman ps -a --external --format json · podman images --format json"
}

// testish names are what a container started by hand to try something
// tends to be called.
var testish = []string{"test", "tmp", "temp", "scratch", "try", "debug"}

func (p Podman) Load(ctx context.Context, h Host, env Env) ([]Item, error) {
	now := time.Now
	if p.Now != nil {
		now = p.Now
	}
	out, err := run(ctx, h, "podman", "ps", "-a", "--external", "--format", "json")
	if err != nil {
		return nil, err
	}
	var cs []podmanContainer
	if err := json.Unmarshal(out, &cs); err != nil {
		return nil, fmt.Errorf("podman ps: bad JSON: %w", err)
	}
	// buildah owns build containers: buildah rm unmounts, then removes.
	// Without it, podman needs --force for a mounted one.
	_, err = run(ctx, h, "buildah", "--version")
	hasBuildah := err == nil
	var items []Item
	for _, c := range cs {
		items = append(items, containerItem(c, now(), hasBuildah))
	}
	out, err = run(ctx, h, "podman", "images", "--format", "json")
	if err != nil {
		return items, err
	}
	var imgs []podmanImage
	if err := json.Unmarshal(out, &imgs); err != nil {
		return items, fmt.Errorf("podman images: bad JSON: %w", err)
	}
	flkImages := 0
	seen := map[string]bool{}
	for _, im := range imgs {
		if seen[im.ID] {
			continue // podman lists an image once per name
		}
		seen[im.ID] = true
		if len(im.Names) > 0 && strings.HasPrefix(im.Names[0], "flk.local/") {
			flkImages++
			continue
		}
		items = append(items, imageItem(im))
	}
	if flkImages > 0 {
		items = append(items, Item{Key: "podman/flk", Label: fmt.Sprintf("%d flk images: host Images tab", flkImages),
			State: Off, Title: "flk's images",
			Lines: []string{"flk.local/* images are flk's releases: see the host's Images tab (flk images),",
				"where each is linked to its app. flk apps prune removes those of apps that are gone."}})
	}
	return items, nil
}

func containerItem(c podmanContainer, now time.Time, hasBuildah bool) Item {
	name := c.ID[:min(12, len(c.ID))]
	if len(c.Names) > 0 {
		name = c.Names[0]
	}
	it := Item{Key: "podman/c/" + c.ID, Title: "container " + name}
	build := c.State == "storage" || (len(c.Command) > 0 && c.Command[0] == "buildah")
	// every build has one while it runs: only an old one was left behind
	// (the same hour flk's doctor uses)
	stale := build && c.Created > 0 && now.Sub(time.Unix(c.Created, 0)) > time.Hour
	switch {
	case build && !stale:
		it.Label, it.State = "▢ "+name+" (building)", Off
	case build:
		it.Label, it.State = "▢ "+name+" (build)", Warn
	case c.State == "running":
		it.Label = "● " + name
	default:
		it.Label, it.State = "○ "+name, Off
	}
	it.Lines = []string{
		field("id", c.ID[:min(12, len(c.ID))]),
		field("image", c.Image),
		field("state", c.Status),
	}
	if c.Created > 0 {
		it.Lines = append(it.Lines, field("created", time.Unix(c.Created, 0).UTC().Format("2006-01-02 15:04Z")))
	}
	if build && !stale {
		it.Lines = append(it.Lines, "",
			"A build's working container (buildah): every build has one while it runs.",
			"If it's still here an hour from now, the build was interrupted and left it.")
		return it
	}
	if build {
		it.Lines = append(it.Lines, "",
			"A build container (buildah's working container), over an hour old: a build",
			"that was interrupted (e.g. Ctrl-C during flk deploy) left it behind. It pins",
			"its image's layers. Nothing runs in it; removing it is safe.")
		id := c.ID[:min(12, len(c.ID))]
		rm := actions.Command{Program: "buildah", Args: []string{"rm", id}}
		how := "buildah rm: unmounts it, then removes it"
		if !hasBuildah {
			// a build container is usually still mounted; nothing runs in it
			rm = actions.Command{Program: "podman", Args: []string{"rm", "--force", "--storage", id}}
			how = "podman rm --force --storage: it's still mounted, but nothing runs in it"
		}
		a := actions.Run("D", "remove", "remove this leftover build container ("+how+")", actions.Type, name, rm)
		it.Actions = append(it.Actions, a)
		it.Problems = append(it.Problems, fmt.Sprintf("podman: build container %s was left behind (an interrupted build?): %s", name, rm.Line()))
		it.Fix = &a
		return it
	}
	started := time.Unix(c.StartedAt, 0)
	if c.State == "running" && c.StartedAt > 0 {
		up := now.Sub(started)
		it.Lines = append(it.Lines, field("up", fmt.Sprintf("%s (since %s)", up.Round(time.Minute), started.UTC().Format("2006-01-02 15:04Z"))))
		lower := strings.ToLower(name)
		odd := strings.HasPrefix(c.Image, "localhost/")
		for _, w := range testish {
			if strings.Contains(lower, w) {
				odd = true
			}
		}
		if odd && up > 24*time.Hour {
			it.State = Warn
			it.Problems = append(it.Problems, fmt.Sprintf("podman: %s has been running %s and looks like a test (%s): stop it?",
				name, up.Round(time.Hour), c.Image))
		}
		stop := actions.Run("S", "stop", "stop it (podman stop)", actions.Ask, "",
			actions.Command{Program: "podman", Args: []string{"stop", name}, Warn: "Stops " + name + "."})
		it.Actions = append(it.Actions, stop)
		if it.State == Warn {
			it.Fix = &stop
		}
	} else {
		rm := actions.Run("D", "remove", "delete it (podman rm)", actions.Type, name,
			actions.Command{Program: "podman", Args: []string{"rm", name}, Warn: "Deletes the container " + name + " and its writable layer."})
		it.Actions = append(it.Actions, rm)
	}
	logs := actions.Command{Program: "podman", Args: []string{"logs", "-f", "--tail", "1000", name}}
	it.Logs = &logs
	it.Actions = append(it.Actions, actions.FollowLogs("l", "follow its output (podman logs -f)", logs))
	return it
}

func imageItem(im podmanImage) Item {
	short := im.ID[:min(12, len(im.ID))]
	name := short + " (untagged)"
	if len(im.Names) > 0 {
		name = im.Names[0]
	}
	it := Item{Key: "podman/i/" + im.ID, Title: "image " + name, State: Off,
		Label: fmt.Sprintf("◇ %s %s", shortRef(name), human(im.Size))}
	it.Lines = []string{field("id", short), field("size", human(im.Size)), field("created", im.CreatedAt)}
	for i, n := range im.Names {
		label := ""
		if i == 0 {
			label = "names"
		}
		it.Lines = append(it.Lines, field(label, n))
	}
	use := "no container uses it"
	if im.Containers > 0 {
		use = fmt.Sprintf("%d container(s) use it", im.Containers)
	}
	it.Lines = append(it.Lines, field("used", use), "",
		"Not one of flk's (flk.local/*). A Dockerfile's FROM image stays here as",
		"the build cache, so later deploys don't download it again.")
	ref := short
	if len(im.Names) > 0 {
		ref = im.Names[0]
	}
	rm := "podman image rm " + ref
	it.Actions = append(it.Actions,
		actions.CopyOnly("c", "copy: "+rm, "lazyflk doesn't delete images; paste it in a shell", rm),
		actions.CopyOnly("p", "copy: podman image prune", "removes images nothing uses or tags (dangling ones)", "podman image prune"))
	return it
}

// shortRef drops the registry and library/ from an image name.
func shortRef(ref string) string {
	if i := strings.Index(ref, "/"); i > 0 && strings.ContainsAny(ref[:i], ".:") {
		ref = ref[i+1:]
	}
	return strings.TrimPrefix(ref, "library/")
}
