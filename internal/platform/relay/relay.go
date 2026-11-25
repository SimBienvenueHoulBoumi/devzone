// Package relay keeps the detached kubectl port-forward of a devzone service
// alive, with the PID and the journal in workspace/.<service>.
package relay

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
)

// Launcher starts the detached relay and returns its process ID. Tests replace
// it to observe the requested port-forward without starting a process.
type Launcher func(dir, name, contextName, ns, target string, ports []string) (int, error)

// Start starts the relay once. A live PID file means it is already running.
func Start(dir, name, contextName, ns, target string, ports []string, launcher Launcher) error {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	if Active(dir, name) {
		return nil
	}
	if launcher == nil {
		launcher = launch
	}
	pid, err := launcher(dir, name, contextName, ns, target, ports)
	if err != nil {
		return err
	}
	return os.WriteFile(pidFile(dir, name), []byte(strconv.Itoa(pid)+"\n"), 0o644)
}

// Stop kills the relay loop and its port-forward child, then removes the PID.
func Stop(dir, name string) {
	pid, ok := readPID(dir, name)
	if !ok {
		return
	}
	children := childPIDs(pid)
	kill(pid)
	for _, child := range children {
		kill(child)
	}
	_ = os.Remove(pidFile(dir, name))
}

// Active reports whether the PID file names a live process.
func Active(dir, name string) bool {
	pid, ok := readPID(dir, name)
	return ok && signal(pid, syscall.Signal(0)) == nil
}

// pidFile returns the path of the relay PID file.
func pidFile(dir, name string) string {
	_ = name
	return filepath.Join(dir, "relais.pid")
}

// readPID reads the PID file; an absent or invalid file means no relay.
func readPID(dir, name string) (int, bool) {
	data, err := os.ReadFile(pidFile(dir, name))
	if err != nil {
		return 0, false
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(data)))
	if err != nil || pid <= 0 {
		return 0, false
	}
	return pid, true
}

// childPIDs lists the children of pid before the loop is killed.
func childPIDs(pid int) []int {
	res, err := exec.Command("pgrep", "-P", strconv.Itoa(pid)).Output()
	if err != nil {
		return nil
	}
	var out []int
	for _, field := range strings.Fields(string(res)) {
		if child, err := strconv.Atoi(field); err == nil {
			out = append(out, child)
		}
	}
	return out
}

// kill sends SIGTERM to pid, ignoring a process already gone.
func kill(pid int) { _ = signal(pid, syscall.SIGTERM) }

// signal sends sig to pid through the OS process table.
func signal(pid int, sig syscall.Signal) error {
	process, err := os.FindProcess(pid)
	if err != nil {
		return err
	}
	return process.Signal(sig)
}

// launch starts the same detached loop as relay_start of cluster.sh: nohup and,
// when available, setsid keep it alive after the installer exits.
func launch(dir, name, contextName, ns, target string, ports []string) (int, error) {
	logPath := filepath.Join(dir, "relais.log")
	log, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
	if err != nil {
		return 0, err
	}
	defer log.Close()
	args := []string{"bash", "-c", loopScript, contextName, ns, target}
	args = append(args, ports...)
	binary := "nohup"
	if _, err := exec.LookPath("setsid"); err == nil {
		binary = "setsid"
		args = append([]string{"nohup"}, args...)
	}
	cmd := exec.Command(binary, args...)
	cmd.Stdout = log
	cmd.Stderr = log
	if err := cmd.Start(); err != nil {
		return 0, fmt.Errorf("relay %s: %w", name, err)
	}
	pid := cmd.Process.Pid
	go func() { _ = cmd.Wait() }()
	return pid, nil
}
