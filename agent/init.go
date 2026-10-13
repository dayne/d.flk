package main

// PID 1 for images without /bin/sh (scratch, distroless): the same job as
// share/init.sh, which every image with a shell keeps using. flk-build-rootfs
// installs this binary as /flk/init only when the image has no /bin/sh.
// Log lines match init.sh's: flk reads "[flk-init] app exited with status N".

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"
)

func logf(format string, a ...any) { fmt.Printf("[flk-init] "+format+"\n", a...) }

func runInit() {
	os.Setenv("PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
	mnt := func(src, dst, typ, opts string) {
		os.MkdirAll(dst, 0o755)
		if err := syscall.Mount(src, dst, typ, 0, opts); err != nil && err != syscall.EBUSY {
			logf("WARNING: mount %s on %s: %v", typ, dst, err)
		}
	}
	mnt("proc", "/proc", "proc", "")
	mnt("sysfs", "/sys", "sysfs", "")
	mnt("devtmpfs", "/dev", "devtmpfs", "")
	mnt("devpts", "/dev/pts", "devpts", "")
	mnt("tmpfs", "/dev/shm", "tmpfs", "")
	mnt("tmpfs", "/run", "tmpfs", "")
	for l, t := range map[string]string{"/dev/fd": "/proc/self/fd", "/dev/stdin": "/proc/self/fd/0",
		"/dev/stdout": "/proc/self/fd/1", "/dev/stderr": "/proc/self/fd/2", "/dev/core": "/proc/kcore"} {
		os.Remove(l)
		os.Symlink(t, l)
	}
	write := func(p, s string) { os.WriteFile(p, []byte(s), 0o644) }
	write("/proc/sys/kernel/ctrl-alt-del", "0") // Ctrl-Alt-Del: SIGINT to us, not a hard reboot
	write("/proc/sys/vm/dirty_expire_centisecs", "100")
	write("/proc/sys/vm/dirty_writeback_centisecs", "100")

	os.MkdirAll("/flk/config", 0o755)
	if err := syscall.Mount("/dev/vdb", "/flk/config", "ext4", syscall.MS_RDONLY, ""); err != nil {
		logf("WARNING: config drive missing: %v", err)
	}
	env := map[string]string{}
	for _, f := range []string{"/flk/image.env", "/flk/config/env"} {
		readEnvFile(f, env)
	}
	for k, v := range env {
		os.Setenv(k, v)
	}
	write("/proc/sys/kernel/hostname", env["FLK_HOSTNAME"])
	if fib, _ := os.ReadFile("/proc/net/fib_trie"); env["FLK_IP"] != "" && !strings.Contains(string(fib), env["FLK_IP"]) {
		logf("WARNING: eth0 not configured by the kernel (and this init can't do it without ip)")
	}
	os.MkdirAll("/etc", 0o755)
	os.Remove("/etc/resolv.conf")
	var rc strings.Builder
	for _, ns := range strings.Fields(env["FLK_DNS"]) {
		fmt.Fprintf(&rc, "nameserver %s\n", ns)
	}
	write("/etc/resolv.conf", rc.String())
	hosts, _ := os.ReadFile("/etc/hosts")
	h := string(hosts)
	if !strings.Contains(h, "localhost") {
		h += "127.0.0.1 localhost\n"
	}
	write("/etc/hosts", h+env["FLK_IP"]+" "+env["FLK_HOSTNAME"]+"\n")

	mounts := readMounts()
	for _, m := range mounts {
		os.MkdirAll(m[1], 0o755)
		if err := syscall.Mount(m[0], m[1], "ext4", 0, "commit=1"); err != nil {
			logf("WARNING: failed to mount %s at %s: %v", m[0], m[1], err)
		} else {
			logf("mounted volume %s at %s", m[0], m[1])
		}
	}

	// the agent, as its own process (its commands are its children)
	if self, err := os.Executable(); err == nil {
		devnull, _ := os.Open(os.DevNull)
		os.StartProcess(self, []string{"flk-agent"}, &os.ProcAttr{Dir: "/", Env: os.Environ(),
			Files: []*os.File{devnull, os.Stdout, os.Stderr}})
	}

	argv := readCmd()
	wd, _ := os.ReadFile("/flk/workdir")
	dir := strings.TrimSpace(string(wd))
	if st, err := os.Stat(dir); dir == "" || err != nil || !st.IsDir() {
		dir = "/"
	}
	attr := &syscall.SysProcAttr{}
	if u, _ := os.ReadFile("/flk/user"); strings.TrimSpace(string(u)) != "" {
		us := strings.TrimSpace(string(u))
		if us != "root" && us != "0" && us != "0:0" {
			if cred, _, err := lookupUser(us); err == nil {
				attr.Credential = cred
			} else {
				logf("WARNING: can't switch to user '%s' (%v); running as root", us, err)
			}
		}
	}
	stdin, err := os.Open("/dev/console")
	if env["FLK_STDIN"] == "null" || err != nil {
		stdin, _ = os.Open(os.DevNull)
	}

	sigs := make(chan os.Signal, 8)
	signal.Notify(sigs, syscall.SIGINT, syscall.SIGTERM, syscall.SIGCHLD)
	status := 127
	app := 0
	if len(argv) == 0 {
		logf("no command to run (the image has no CMD/ENTRYPOINT)")
	} else if path, err := lookPath(argv[0]); err != nil {
		logf("can't start %s: %v", argv[0], err)
	} else {
		logf("starting app: %s", strings.Join(argv, " "))
		p, err := os.StartProcess(path, argv, &os.ProcAttr{Dir: dir, Env: os.Environ(),
			Files: []*os.File{stdin, os.Stdout, os.Stderr}, Sys: attr})
		if err != nil {
			logf("can't start %s: %v", argv[0], err)
		} else {
			app = p.Pid
		}
	}
	for app != 0 {
		s := <-sigs
		switch s {
		case syscall.SIGINT, syscall.SIGTERM:
			logf("shutdown requested, sending SIGTERM to app")
			syscall.Kill(app, syscall.SIGTERM)
		case syscall.SIGCHLD:
			for { // PID 1 reaps every orphan
				var ws syscall.WaitStatus
				pid, err := syscall.Wait4(-1, &ws, syscall.WNOHANG, nil)
				if pid <= 0 || err != nil {
					break
				}
				if pid == app {
					status = ws.ExitStatus()
					if ws.Signaled() {
						status = 128 + int(ws.Signal())
					}
					app = 0
				}
			}
		}
	}
	logf("app exited with status %d; powering off", status)

	syscall.Kill(-1, syscall.SIGTERM)
	time.Sleep(time.Second)
	syscall.Kill(-1, syscall.SIGKILL)
	syscall.Sync()
	for i := len(mounts) - 1; i >= 0; i-- {
		if syscall.Unmount(mounts[i][1], 0) != nil &&
			syscall.Mount("", mounts[i][1], "", syscall.MS_REMOUNT|syscall.MS_RDONLY, "") != nil {
			logf("WARNING: couldn't unmount or remount read-only %s; it will need journal recovery", mounts[i][1])
		}
	}
	syscall.Unmount("/flk/config", 0)
	syscall.Mount("", "/", "", syscall.MS_REMOUNT|syscall.MS_RDONLY, "")
	syscall.Sync()
	syscall.Reboot(syscall.LINUX_REBOOT_CMD_RESTART) // firecracker exits (reboot=k)
	time.Sleep(5 * time.Second)
}

// "export K=V" lines, V quoted as Ruby's Shellwords.escape does.
func readEnvFile(path string, env map[string]string) {
	f, err := os.Open(path)
	if err != nil {
		return
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1<<20), 1<<20)
	for sc.Scan() {
		line := strings.TrimPrefix(sc.Text(), "export ")
		k, v, ok := strings.Cut(line, "=")
		if ok && k != "" {
			env[k] = shellUnquote(v)
		}
	}
}

func shellUnquote(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		switch c := s[i]; c {
		case '\\':
			if i+1 < len(s) {
				i++
				b.WriteByte(s[i])
			}
		case '\'':
			j := strings.IndexByte(s[i+1:], '\'')
			if j < 0 {
				b.WriteString(s[i+1:])
				return b.String()
			}
			b.WriteString(s[i+1 : i+1+j])
			i += j + 1
		default:
			b.WriteByte(c)
		}
	}
	return b.String()
}

func readMounts() [][2]string {
	data, err := os.ReadFile("/flk/config/mounts")
	if err != nil {
		return nil
	}
	var out [][2]string
	for _, l := range strings.Split(string(data), "\n") {
		f := strings.Fields(l)
		if len(f) == 2 {
			out = append(out, [2]string{f[0], f[1]})
		}
	}
	return out
}

func readCmd() []string {
	var argv []string
	if data, err := os.ReadFile("/flk/cmd.json"); err == nil {
		json.Unmarshal(data, &argv)
	}
	return argv
}

func lookPath(name string) (string, error) {
	if strings.Contains(name, "/") {
		if _, err := os.Stat(name); err != nil {
			return "", err
		}
		return name, nil
	}
	for _, d := range strings.Split(os.Getenv("PATH"), ":") {
		p := d + "/" + name
		if st, err := os.Stat(p); err == nil && !st.IsDir() && st.Mode()&0o111 != 0 {
			return p, nil
		}
	}
	return "", fmt.Errorf("not found in PATH")
}
