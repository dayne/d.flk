package flk

// Types mirror flk's JSON output. Every field is optional: flk may omit or
// null any of them, and unknown fields are ignored. Timestamps stay strings
// so a format change degrades one value, not the whole decode.

// Schema is the JSON schema version lazyflk understands (flk's G6 rule:
// new fields keep the number; renaming, removing or retyping bumps it).
// 0 means an older flk that doesn't say.
const Schema = 1

// HostContext is `flk context --all --json` (with --no-host, Host has
// only LanIP and NextSteps only the per-app items).
type HostContext struct {
	Schema    int      `json:"schema"`
	Flk       FlkInfo  `json:"flk"`
	MountDirs []string `json:"mount_dirs"`
	Host      Host     `json:"host"`
	Apps      []App    `json:"apps"`
	NextSteps []string `json:"next_steps"`
}

type FlkInfo struct {
	Version   string `json:"version"`
	StateDir  string `json:"state_dir"`
	Source    string `json:"source"`
	Reference string `json:"reference"`
}

type Host struct {
	OK          bool          `json:"ok"`
	Problems    []DoctorCheck `json:"problems"`
	LanIP       string        `json:"lan_ip"`
	Address     string        `json:"address"` // the address to advertise (host.toml), else lan_ip
	BootService bool          `json:"boot_service"`
	Services    []Service     `json:"services"`
}

// Service is one of flk's systemd units (flk-net, flk-machines). Both are
// oneshot: healthy is active "active", sub "exited".
type Service struct {
	Unit      string `json:"unit"`
	Installed bool   `json:"installed"`
	Enabled   *bool  `json:"enabled"`
	Active    string `json:"active"` // active, inactive, failed, ...
	Sub       string `json:"sub"`
	Result    string `json:"result"`
	Since     string `json:"since"`
}

// App is one entry of context's "apps" (or its "app").
type App struct {
	Name       string    `json:"name"`
	Registered bool      `json:"registered"`
	Home       string    `json:"home"`
	ConfigPath string    `json:"config_path"` // null until launched/deployed by flk with G2
	Release    *Release  `json:"release"`
	Releases   int       `json:"releases"`
	Scale      *int      `json:"scale"`
	Machines   []Machine `json:"machines"`
	Volumes    []Volume  `json:"volumes"`
	Secrets    []string  `json:"secrets"`
	Ports      PortTable `json:"ports"`
}

type Release struct {
	Version   int    `json:"version"`
	Tag       string `json:"tag"`
	Path      string `json:"path"`
	Source    string `json:"source"`
	CreatedAt string `json:"created_at"`
	// releases list only (flk 1d428f4)
	Current    bool   `json:"current"`
	Image      bool   `json:"image"`    // its image is kept: it can be rolled back to
	Machines   int    `json:"machines"` // machines on it now
	Status     string `json:"status"`   // "failed", or empty
	Failure    string `json:"failure"`  // why it failed its health checks
	FailedAt   string `json:"failed_at"`
	RollbackOf int    `json:"rollback_of"` // the release it copies, for a rollback
	// volumes backed up by the roll to this release (flk 3f618a4,
	// [flk.backup] before_deploy): the data from before it
	Backups []ReleaseBackup `json:"backups"`
}

type ReleaseBackup struct {
	Machine  string `json:"machine"`
	Volume   string `json:"volume"`
	VolumeID string `json:"volume_id"`
	File     string `json:"file"`
}

// Failed reports a release that failed its health checks on deploy.
func (r Release) Failed() bool { return r.Status == "failed" }

type Machine struct {
	ID           string        `json:"id"`
	Name         string        `json:"name"`
	State        string        `json:"state"`
	DesiredState string        `json:"desired_state"`
	PID          *int          `json:"pid"` // firecracker's; null when not running
	Restart      *Restart      `json:"restart"`
	Restarts     *Restarts     `json:"restarts"`
	Release      int           `json:"release"`
	IP           string        `json:"ip"`
	CPUs         int           `json:"cpus"`
	MemoryMB     int           `json:"memory_mb"`
	HugePages    string        `json:"huge_pages"` // "2M", or empty for normal pages
	InternalPort int           `json:"internal_port"`
	Ports        []MachinePort `json:"ports"`
	Volumes      []Mount       `json:"volumes"`
	CreatedAt    string        `json:"created_at"`
	UpdatedAt    string        `json:"updated_at"`
}

// Restart is a machine's restart policy ([[restart]] in flk.toml).
type Restart struct {
	Policy  string `json:"policy"` // on-failure, always, never
	Retries int    `json:"retries"`
}

// Restarts is the restart policy's running count; null when it hasn't acted.
type Restarts struct {
	Count    int    `json:"count"`
	LastAt   string `json:"last_at"`
	GaveUpAt string `json:"gave_up_at"`
}

// Started reports whether the machine is running.
func (m Machine) Started() bool { return m.State == "started" }

// ShouldRun reports a machine that is meant to run but doesn't.
func (m Machine) ShouldRun() bool { return m.DesiredState == "started" && !m.Started() }

type MachinePort struct {
	Proto        string `json:"proto"`
	Port         int    `json:"port"`
	InternalPort int    `json:"internal_port"`
}

type Mount struct {
	Volume      string `json:"volume"`
	Source      string `json:"source"`
	Destination string `json:"destination"`
}

type Volume struct {
	ID              string `json:"id"`
	Name            string `json:"name"`
	SizeGB          int    `json:"size_gb"`
	Path            string `json:"path"`
	External        bool   `json:"external"`
	AttachedMachine string `json:"attached_machine"`
	CreatedAt       string `json:"created_at"`
	RestoredFrom    string `json:"restored_from"` // the backup file it was made from (restore --as)
}

// PortTable is the active/waiting/blocked split flk uses everywhere.
type PortTable struct {
	Active  []Port `json:"active"`
	Waiting []Port `json:"waiting"`
	Blocked []Port `json:"blocked"`
}

type Port struct {
	Key          string  `json:"key"`  // proto/port; with binds, (Bind, Key) is the identity
	Bind         *string `json:"bind"` // a host address, or null for every address
	Proto        string  `json:"proto"`
	Port         int     `json:"port"`
	IP           string  `json:"ip"`
	InternalPort int     `json:"internal_port"`
	App          string  `json:"app"`
	Machine      string  `json:"machine"`
	Address      string  `json:"address"`
	Blocked      string  `json:"blocked"`
}

// AppContext is `flk -a APP context --json`.
type AppContext struct {
	Flk       FlkInfo        `json:"flk"`
	Host      Host           `json:"host"`
	Cwd       string         `json:"cwd"`
	App       *App           `json:"app"`
	OtherApps []AppSummary   `json:"other_apps"`
	NextSteps []string       `json:"next_steps"`
	Config    map[string]any `json:"config"`
}

// AppSummary is a row of `flk apps list --json`.
type AppSummary struct {
	Name       string `json:"name"`
	Machines   int    `json:"machines"`
	Started    int    `json:"started"`
	Release    int    `json:"release"`
	ConfigPath string `json:"config_path"`
}

// Doctor is `flk doctor --json`.
type Doctor struct {
	Schema   int           `json:"schema"`
	OK       bool          `json:"ok"`
	Checks   []DoctorCheck `json:"checks"`
	Services []Service     `json:"services"`
}

type DoctorCheck struct {
	Label  string `json:"label"`
	Status string `json:"status"` // pass, warn, fail
	Hint   string `json:"hint"`
}

// PortsList is `flk ports list --json`.
type PortsList struct {
	HelperInstalled bool   `json:"helper_installed"`
	PerAddress      *bool  `json:"per_address"` // the helper supports bind
	MinPort         int    `json:"min_port"`
	HostAddress     string `json:"host_address"`
	PortTable
}

// Status is `flk -a APP status --json`.
type Status struct {
	App struct {
		Name       string   `json:"name"`
		Release    *Release `json:"release"`
		Home       string   `json:"home"`
		ConfigPath string   `json:"config_path"`
	} `json:"app"`
	Machines []Machine `json:"machines"`
}

// Secret is a row of `flk -a APP secrets list --json` (never the value).
type Secret struct {
	Name   string `json:"name"`
	Digest string `json:"digest"`
}

// MachineRecord is `flk -a APP machine status ID`.
type MachineRecord struct {
	ID           string        `json:"id"`
	Name         string        `json:"name"`
	App          string        `json:"app"`
	TapIndex     int           `json:"tap_index"`
	IP           string        `json:"ip"`
	MAC          string        `json:"mac"`
	Release      int           `json:"release"`
	Config       MachineConfig `json:"config"`
	CreatedAt    string        `json:"created_at"`
	UpdatedAt    string        `json:"updated_at"`
	StartedAt    string        `json:"started_at"`
	StoppedAt    string        `json:"stopped_at"`
	DesiredState string        `json:"desired_state"`
	State        string        `json:"state"`
}

type MachineConfig struct {
	CPUs         int               `json:"cpus"`
	MemoryMB     int               `json:"memory_mb"`
	Env          map[string]string `json:"env"`
	MountSpecs   []Mount           `json:"mount_specs"`
	InternalPort int               `json:"internal_port"`
	Ports        []MachinePort     `json:"ports"`
	KillTimeout  int               `json:"kill_timeout"`
	KernelArgs   string            `json:"kernel_args"`
	Stdin        string            `json:"stdin"`
	Restart      *Restart          `json:"restart"`
	Mounts       []Mount           `json:"mounts"`
	Checks       []Check           `json:"checks"`
	HugePages    string            `json:"huge_pages"`
}

// Check is a health check a machine must pass on deploy (flk 1d428f4).
type Check struct {
	Name        string `json:"name"`
	Type        string `json:"type"` // tcp, http, log
	GracePeriod int    `json:"grace_period"`
	Port        int    `json:"port"`
	Path        string `json:"path"`
	Match       string `json:"match"` // log: the line to wait for
}

// ConfigShow is `flk config show`: what flk understood of the app's config.
type ConfigShow struct {
	File          string        `json:"file"`
	MachineConfig MachineConfig `json:"machine_config"`
	Warnings      []string      `json:"warnings"`
}

// Help is `flk help --all --json`: the command table.
type Help struct {
	Schema        int               `json:"schema"`
	Version       string            `json:"version"`
	StateDir      string            `json:"state_dir"`
	GlobalOptions []Option          `json:"global_options"`
	ExitCodes     map[string]string `json:"exit_codes"`
	Commands      []Command         `json:"commands"`
	Topics        map[string]string `json:"topics"`
}

type Command struct {
	Name              string    `json:"name"`
	Usage             string    `json:"usage"`
	Summary           string    `json:"summary"`
	Args              string    `json:"args"`
	Aliases           []string  `json:"aliases"`
	Options           []Option  `json:"options"`
	JSON              bool      `json:"json"`
	Blocks            string    `json:"blocks"`
	Notes             []string  `json:"notes"`
	DefaultSubcommand string    `json:"default_subcommand"`
	Subcommands       []Command `json:"subcommands"`
}

type Option struct {
	Switches    []string `json:"switches"`
	Description string   `json:"description"`
}

// Backup is a row of `flk -a APP volumes backups --json`, newest first.
type Backup struct {
	File      string  `json:"file"`
	Path      string  `json:"path"`
	CreatedAt string  `json:"created_at"`
	BytesUsed int64   `json:"bytes_used"`
	Volume    string  `json:"volume"` // the volume's name
	App       string  `json:"app"`
	VolumeID  string  `json:"volume_id"`
	SizeGB    int     `json:"size_gb"`
	Source    string  `json:"source"`
	Machine   string  `json:"machine"`
	Release   int     `json:"release"`
	Mode      string  `json:"mode"`  // stop, live, pause, offline
	Check     string  `json:"check"` // clean, repaired, errors, unchecked
	Journal   bool    `json:"journal_replayed"`
	Seconds   float64 `json:"seconds"`
	// flk volumes verify (flk 4ff9e9b); empty until it's been verified
	Verify       string `json:"verify"` // clean, errors, hook_failed
	VerifiedAt   string `json:"verified_at"`
	VerifyDetail string `json:"verify_detail"`
	// a backup a deploy took before rolling (flk 3f618a4): Reason
	// "before_deploy", Release the release the machine left, ForRelease
	// the one being deployed
	Reason     string `json:"reason"`
	ForRelease int    `json:"for_release"`
	// copies elsewhere (flk a04fcc6): one per destination, latest attempt
	Copies []BackupCopy `json:"copies"`
}

// BackupCopy is a backup's copy at one destination (backup_copy_to or
// volumes copy --dest).
type BackupCopy struct {
	To      string  `json:"to"` // a local dir, or HOST:DIR
	At      string  `json:"at"`
	OK      bool    `json:"ok"`
	Seconds float64 `json:"seconds"`
	Error   string  `json:"error"`
}

// Event is a line of `flk events --json` (flk c0a98f4, G7): something
// that happened to an app or machine. Machine is "" for app events
// (deploy.*, backup.copied); Release and Detail when there's one.
type Event struct {
	At      string `json:"at"` // UTC, milliseconds
	App     string `json:"app"`
	Machine string `json:"machine"`
	Type    string `json:"type"` // machine.started, deploy.failed, … (flk help --all, "Events")
	Release int    `json:"release"`
	Detail  string `json:"detail"`
}

// FileEntry is a row of `flk files ls VOL:PATH --json` (flk ef6f865).
type FileEntry struct {
	Name  string `json:"name"`
	Type  string `json:"type"` // file, dir, symlink, other
	Size  int64  `json:"size"`
	UID   int    `json:"uid"`
	GID   int    `json:"gid"`
	Mode  string `json:"mode"`  // "0644"
	MTime string `json:"mtime"` // to the minute
}

// FilesArgs is a flk files read (ls, cat, cp out) of VOL:PATH in app,
// from a backup when backup isn't "".
func FilesArgs(app, sub, vol, path, backup string, rest ...string) []string {
	args := []string{"-a", app, "files", sub, vol + ":" + path}
	args = append(args, rest...)
	if backup != "" {
		args = append(args, "--backup", backup)
	}
	return args
}

// MachineStats is a row of `flk machine stats --all --json`. The live
// numbers are null when the machine isn't running.
type MachineStats struct {
	App        string   `json:"app"`
	ID         string   `json:"id"`
	Name       string   `json:"name"`
	State      string   `json:"state"`
	PID        *int     `json:"pid"`
	CPUs       int      `json:"cpus"`
	MemoryMB   int      `json:"memory_mb"`
	CPUPercent *float64 `json:"cpu_percent"` // 100 = one host CPU
	RSSMB      *int     `json:"rss_mb"`
	UptimeS    *int     `json:"uptime_s"`
}

// Size is disk use: Bytes allocated (sparse-aware) and Apparent.
type Size struct {
	Bytes    int64 `json:"bytes"`
	Apparent int64 `json:"apparent"`
}

// DiskUse is `flk disk --json`: what flk keeps where.
type DiskUse struct {
	StateDir struct {
		Path string `json:"path"`
		Size
	} `json:"state_dir"`
	Apps   []AppDisk `json:"apps"`
	Totals struct {
		Images          Size `json:"images"`
		Rootfs          Size `json:"rootfs"`
		Volumes         Size `json:"volumes"`
		Logs            Size `json:"logs"`
		ExternalVolumes Size `json:"external_volumes"`
	} `json:"totals"`
	Backups *struct {
		Dir string `json:"dir"`
		Size
		Apps map[string]BackupUse `json:"apps"`
	} `json:"backups"` // null without a backup_dir
}

// BackupUse is one app's backups; Volumes is per volume name (flk 4b26b65).
type BackupUse struct {
	Size
	Volumes map[string]struct {
		Size
		Count int `json:"count"`
	} `json:"volumes"`
}

// AppDisk is one app's use; Total is inside the state dir (external
// volumes aren't in it).
type AppDisk struct {
	App             string `json:"app"`
	Images          Size   `json:"images"`
	Rootfs          Size   `json:"rootfs"`
	Volumes         Size   `json:"volumes"`
	Logs            Size   `json:"logs"`
	ExternalVolumes Size   `json:"external_volumes"`
	Total           Size   `json:"total"`
}

// Image is a row of `flk images --json`, one per tag (two tags of one
// image share ID and size).
type Image struct {
	Repo      string `json:"repo"`
	Tag       string `json:"tag"`
	ID        string `json:"id"`
	SizeBytes int64  `json:"size_bytes"`
	CreatedAt string `json:"created_at"`
	App       string `json:"app"`
	Release   *int   `json:"release"`
	Orphan    bool   `json:"orphan"`  // its app is gone (apps prune)
	Current   bool   `json:"current"` // the app's latest release
	InUse     bool   `json:"in_use"`  // a machine is on it
	Running   bool   `json:"running"` // a running machine is on it
}

// Shown is a port as flk's text output shows it: "tcp/25565", or
// "10.47.11.3:tcp/25565" when it's bound to one address.
func (p Port) Shown() string {
	if p.Bind != nil && *p.Bind != "" {
		return *p.Bind + ":" + p.Key
	}
	return p.Key
}
