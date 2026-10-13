package flk

// Types mirror flk's JSON output. Every field is optional: flk may omit or
// null any of them, and unknown fields are ignored. Timestamps stay strings
// so a format change degrades one value, not the whole decode.

// HostContext is `flk context --all --json`.
type HostContext struct {
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
	BootService bool          `json:"boot_service"`
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
}

type Machine struct {
	ID           string        `json:"id"`
	Name         string        `json:"name"`
	State        string        `json:"state"`
	DesiredState string        `json:"desired_state"`
	Restart      *Restart      `json:"restart"`
	Restarts     *Restarts     `json:"restarts"`
	Release      int           `json:"release"`
	IP           string        `json:"ip"`
	CPUs         int           `json:"cpus"`
	MemoryMB     int           `json:"memory_mb"`
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
}

// PortTable is the active/waiting/blocked split flk uses everywhere.
type PortTable struct {
	Active  []Port `json:"active"`
	Waiting []Port `json:"waiting"`
	Blocked []Port `json:"blocked"`
}

type Port struct {
	Key          string `json:"key"`
	Proto        string `json:"proto"`
	Port         int    `json:"port"`
	IP           string `json:"ip"`
	InternalPort int    `json:"internal_port"`
	App          string `json:"app"`
	Machine      string `json:"machine"`
	Address      string `json:"address"`
	Blocked      string `json:"blocked"`
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
	OK     bool          `json:"ok"`
	Checks []DoctorCheck `json:"checks"`
}

type DoctorCheck struct {
	Label  string `json:"label"`
	Status string `json:"status"` // pass, warn, fail
	Hint   string `json:"hint"`
}

// PortsList is `flk ports list --json`.
type PortsList struct {
	HelperInstalled bool   `json:"helper_installed"`
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
}

// Help is `flk help --all --json`: the command table.
type Help struct {
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
