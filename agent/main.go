// flk-agent: runs inside every flk microVM (started by /flk/init) and runs
// commands for `flk exec` / `flk ssh console` over vsock. Standard library
// only, static (CGO_ENABLED=0), so it works in any image.
//
// Protocol, after the host's Firecracker vsock handshake: frames of
// [type byte][uint32 big-endian length][payload], both ways.
//
//	host -> agent: 'R' request (JSON, first frame), 'I' stdin data,
//	               'E' stdin closed, 'W' window size (JSON rows/cols),
//	               'S' signal number (decimal text)
//	agent -> host: 'O' stdout, 'D' stderr, 'X' exit (JSON), 'F' failed to start
//
// When the connection drops, the command's process group is killed.
package main

import (
	"bufio"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/user"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"unsafe"
)

const port = 10000

type request struct {
	Argv []string `json:"argv"`
	Env  []string `json:"env"`
	TTY  bool     `json:"tty"`
	User string   `json:"user"`
	Cwd  string   `json:"cwd"`
	Rows uint16   `json:"rows"`
	Cols uint16   `json:"cols"`
}

func main() {
	if len(os.Args) > 1 && os.Args[1] == "--version" {
		fmt.Println("flk-agent 2")
		return
	}
	if os.Getpid() == 1 { // installed as /flk/init (an image without /bin/sh)
		runInit()
		return
	}
	fd, err := listen(port)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[flk-agent] vsock listen failed: %v (no exec for this machine)\n", err)
		os.Exit(1)
	}
	for {
		nfd, _, errno := syscall.Syscall6(syscall.SYS_ACCEPT4, uintptr(fd), 0, 0, syscall.SOCK_CLOEXEC, 0, 0)
		if errno != 0 {
			if errno == syscall.EINTR {
				continue
			}
			fmt.Fprintf(os.Stderr, "[flk-agent] accept: %v\n", errno)
			continue
		}
		go serve(os.NewFile(nfd, "vsock"))
	}
}

// sockaddr_vm
type sockaddrVM struct {
	family    uint16
	reserved1 uint16
	port      uint32
	cid       uint32
	flags     uint8
	zero      [3]uint8
}

func listen(p uint32) (int, error) {
	const afVsock = 40
	fd, err := syscall.Socket(afVsock, syscall.SOCK_STREAM|syscall.SOCK_CLOEXEC, 0)
	if err != nil {
		return -1, err
	}
	sa := sockaddrVM{family: afVsock, port: p, cid: 0xFFFFFFFF} // VMADDR_CID_ANY
	if _, _, e := syscall.Syscall(syscall.SYS_BIND, uintptr(fd), uintptr(unsafe.Pointer(&sa)), unsafe.Sizeof(sa)); e != 0 {
		return -1, e
	}
	if err := syscall.Listen(fd, 16); err != nil {
		return -1, err
	}
	return fd, nil
}

type conn struct {
	f  *os.File
	mu sync.Mutex
}

func (c *conn) send(t byte, p []byte) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	h := make([]byte, 5)
	h[0] = t
	binary.BigEndian.PutUint32(h[1:], uint32(len(p)))
	if _, err := c.f.Write(append(h, p...)); err != nil {
		return err
	}
	return nil
}

func readFrame(r io.Reader) (byte, []byte, error) {
	h := make([]byte, 5)
	if _, err := io.ReadFull(r, h); err != nil {
		return 0, nil, err
	}
	n := binary.BigEndian.Uint32(h[1:])
	if n > 16<<20 {
		return 0, nil, fmt.Errorf("frame too big")
	}
	p := make([]byte, n)
	_, err := io.ReadFull(r, p)
	return h[0], p, err
}

type writer struct {
	c *conn
	t byte
}

func (w writer) Write(p []byte) (int, error) {
	if err := w.c.send(w.t, p); err != nil {
		return 0, err
	}
	return len(p), nil
}

func serve(f *os.File) {
	defer f.Close()
	c := &conn{f: f}
	r := bufio.NewReader(f)
	t, p, err := readFrame(r)
	if err != nil || t != 'R' {
		return
	}
	var req request
	if err := json.Unmarshal(p, &req); err != nil {
		c.send('F', []byte("bad request: "+err.Error()))
		return
	}
	cmd, ptmx, stdinW, err := start(&req, c)
	if err != nil {
		c.send('F', []byte(err.Error()))
		return
	}
	var stdin io.WriteCloser = ptmx
	if ptmx == nil {
		stdin = stdinW
	}
	done := make(chan struct{})
	// host -> command
	go func() {
		for {
			t, p, err := readFrame(r)
			if err != nil { // the host went away: end the command
				select {
				case <-done:
				default:
					syscall.Kill(-cmd.Process.Pid, syscall.SIGHUP)
					syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
				}
				return
			}
			switch t {
			case 'I':
				stdin.Write(p)
			case 'E':
				if ptmx != nil {
					ptmx.Write([]byte{4}) // ^D
				} else {
					stdin.Close()
				}
			case 'W':
				var ws struct{ Rows, Cols uint16 }
				if json.Unmarshal(p, &ws) == nil && ptmx != nil {
					setSize(ptmx, ws.Rows, ws.Cols)
				}
			case 'S':
				if n, err := strconv.Atoi(string(p)); err == nil {
					syscall.Kill(-cmd.Process.Pid, syscall.Signal(n))
				}
			}
		}
	}()
	var outDone sync.WaitGroup
	if ptmx != nil {
		outDone.Add(1)
		go func() {
			defer outDone.Done()
			io.Copy(writer{c, 'O'}, ptmx) // ends with EIO once the shell exits
		}()
	}
	err = cmd.Wait()
	close(done)
	if stdinW != nil {
		stdinW.Close()
	}
	if ptmx != nil {
		outDone.Wait()
		ptmx.Close()
	}
	status, sig := 0, ""
	if ee, ok := err.(*exec.ExitError); ok {
		ws := ee.Sys().(syscall.WaitStatus)
		if ws.Signaled() {
			sig = ws.Signal().String()
			status = 128 + int(ws.Signal())
		} else {
			status = ws.ExitStatus()
		}
	} else if err != nil {
		status = 255
	}
	x, _ := json.Marshal(map[string]any{"status": status, "signal": sig})
	c.send('X', x)
}

// The command, and either the pty master (tty) or the stdin pipe's write end.
func start(req *request, c *conn) (*exec.Cmd, *os.File, *os.File, error) {
	argv := req.Argv
	if len(argv) == 0 {
		argv = []string{shell()}
		if argv[0] == "" {
			return nil, nil, nil, fmt.Errorf("this image has no shell (/bin/bash, /bin/sh); pass a command")
		}
		if req.TTY {
			argv = append(argv, "-l")
		}
	}
	path, err := exec.LookPath(argv[0])
	if err != nil {
		return nil, nil, nil, fmt.Errorf("%s: not found in the machine (PATH=%s)", argv[0], os.Getenv("PATH"))
	}
	cmd := exec.Command(path, argv[1:]...)
	cmd.Args[0] = argv[0]
	cmd.Env = append(os.Environ(), req.Env...)
	cmd.Dir = req.Cwd
	if cmd.Dir == "" {
		cmd.Dir = "/"
	}
	attr := &syscall.SysProcAttr{Setsid: true}
	if req.User != "" {
		cred, home, err := lookupUser(req.User)
		if err != nil {
			return nil, nil, nil, err
		}
		attr.Credential = cred
		cmd.Env = append(cmd.Env, "HOME="+home)
	}
	cmd.SysProcAttr = attr
	if req.TTY {
		ptmx, tty, err := openPTY()
		if err != nil {
			return nil, nil, nil, fmt.Errorf("no pty: %v", err)
		}
		defer tty.Close()
		if req.Rows > 0 {
			setSize(ptmx, req.Rows, req.Cols)
		}
		cmd.Stdin, cmd.Stdout, cmd.Stderr = tty, tty, tty
		attr.Setctty = true
		attr.Ctty = 0
		if err := cmd.Start(); err != nil {
			ptmx.Close()
			return nil, nil, nil, err
		}
		return cmd, ptmx, nil, nil
	}
	pr, pw, err := os.Pipe()
	if err != nil {
		return nil, nil, nil, err
	}
	defer pr.Close()
	cmd.Stdin = pr // an *os.File: no copy loop for Wait to wait on
	cmd.Stdout = writer{c, 'O'}
	cmd.Stderr = writer{c, 'D'}
	if err := cmd.Start(); err != nil {
		pw.Close()
		return nil, nil, nil, err
	}
	return cmd, nil, pw, nil
}

func shell() string {
	for _, s := range []string{os.Getenv("SHELL"), "/bin/bash", "/bin/sh", "/busybox/sh"} {
		if s != "" {
			if st, err := os.Stat(s); err == nil && st.Mode()&0o111 != 0 {
				return s
			}
		}
	}
	return ""
}

// "name", "uid" or "uid:gid"
func lookupUser(s string) (*syscall.Credential, string, error) {
	name, group, _ := strings.Cut(s, ":")
	var uid, gid uint64
	home := "/"
	if n, err := strconv.ParseUint(name, 10, 32); err == nil {
		uid, gid = n, n
		if u, err := user.LookupId(name); err == nil {
			gid, _ = strconv.ParseUint(u.Gid, 10, 32)
			home = u.HomeDir
		}
	} else {
		u, err := user.Lookup(name)
		if err != nil {
			return nil, "", fmt.Errorf("no user %q in the machine", name)
		}
		uid, _ = strconv.ParseUint(u.Uid, 10, 32)
		gid, _ = strconv.ParseUint(u.Gid, 10, 32)
		home = u.HomeDir
	}
	if group != "" {
		g, err := strconv.ParseUint(group, 10, 32)
		if err != nil {
			gr, err := user.LookupGroup(group)
			if err != nil {
				return nil, "", fmt.Errorf("no group %q in the machine", group)
			}
			g, _ = strconv.ParseUint(gr.Gid, 10, 32)
		}
		gid = g
	}
	return &syscall.Credential{Uid: uint32(uid), Gid: uint32(gid)}, home, nil
}

func ioctl(fd uintptr, req uintptr, arg uintptr) error {
	if _, _, e := syscall.Syscall(syscall.SYS_IOCTL, fd, req, arg); e != 0 {
		return e
	}
	return nil
}

func openPTY() (*os.File, *os.File, error) {
	ptmx, err := os.OpenFile("/dev/ptmx", os.O_RDWR|syscall.O_NOCTTY, 0)
	if err != nil {
		return nil, nil, err
	}
	var unlock int32
	if err := ioctl(ptmx.Fd(), syscall.TIOCSPTLCK, uintptr(unsafe.Pointer(&unlock))); err != nil {
		ptmx.Close()
		return nil, nil, err
	}
	var n uint32
	if err := ioctl(ptmx.Fd(), syscall.TIOCGPTN, uintptr(unsafe.Pointer(&n))); err != nil {
		ptmx.Close()
		return nil, nil, err
	}
	tty, err := os.OpenFile("/dev/pts/"+strconv.Itoa(int(n)), os.O_RDWR|syscall.O_NOCTTY, 0)
	if err != nil {
		ptmx.Close()
		return nil, nil, err
	}
	return ptmx, tty, nil
}

func setSize(f *os.File, rows, cols uint16) {
	ws := [4]uint16{rows, cols, 0, 0}
	ioctl(f.Fd(), syscall.TIOCSWINSZ, uintptr(unsafe.Pointer(&ws)))
}
