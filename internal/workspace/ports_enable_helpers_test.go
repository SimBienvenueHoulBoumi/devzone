//go:build !windows

package workspace

import (
	"fmt"
	"io"
	"path/filepath"
	"strconv"
	"testing"
	"time"
)

// portsEnableHarness holds the injected folders and functions of the automatic
// start tests: no file reaches the real personal folder and no process is a
// real watcher.
type portsEnableHarness struct {
	t           *testing.T
	agentDir    string
	copyPath    string
	stateDir    string
	binary      string
	kubectl     string
	calls       []portsDaemonCall
	loopCalls   int
	daemonCode  int
	noKubectl   bool
	simulateRun bool
}

// newPortsEnableHarness prepares a Linux instance with a fake watcher binary,
// a fake service manager, a fake start and a fake loop.
func newPortsEnableHarness(t *testing.T) *portsEnableHarness {
	t.Helper()
	h := &portsEnableHarness{t: t}
	h.agentDir = filepath.Join(t.TempDir(), "agents")
	h.stateDir = filepath.Join(t.TempDir(), "state")
	t.Setenv("HOME", t.TempDir())
	t.Setenv("XDG_CACHE_HOME", t.TempDir())
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	t.Setenv("DEVZONE_PORTS_AGENT_DIR", h.agentDir)
	t.Setenv("DEVZONE_PORTS_WORKSPACE_DIR", h.stateDir)
	t.Setenv("DEVZONE_INSTANCE", "alpha")
	t.Setenv("KUBECONFIG", "")
	t.Setenv("DEVZONE_ROOT", filepath.Join(t.TempDir(), "Dev Zone"))
	h.binary = filepath.Join(t.TempDir(), "watcher")
	h.writeBinary("binary v1\n")
	h.copyPath = portsWatcherCopyPath()
	h.kubectl = filepath.Join(t.TempDir(), "my bin", "kubectl")

	oldPlatform, oldExecutable, oldDaemon := portsPlatform, watcherExecutable, portsDaemon
	oldLoop, oldKubectl := portsLoopRunner, portsKubectlPath
	t.Cleanup(func() {
		portsPlatform, watcherExecutable, portsDaemon = oldPlatform, oldExecutable, oldDaemon
		portsLoopRunner, portsKubectlPath = oldLoop, oldKubectl
	})
	portsPlatform = "linux"
	watcherExecutable = func() (string, error) { return h.binary, nil }
	portsKubectlPath = func(string) (string, error) {
		if h.noKubectl {
			return "", fmt.Errorf("kubectl not found")
		}
		return h.kubectl, nil
	}
	portsDaemon = func(tool string, quiet bool, args ...string) int {
		h.calls = append(h.calls, portsDaemonCall{tool: tool, quiet: quiet, args: append([]string(nil), args...)})
		if h.daemonCode != 0 {
			return h.daemonCode
		}
		if h.simulateRun && len(args) > 0 && (args[0] == "bootstrap" || hasArg(args, "start") ||
			(hasArg(args, "enable") && hasArg(args, "--now"))) {
			PortsAgentRun(io.Discard, io.Discard)
		}
		return 0
	}
	portsLoopRunner = func(out, _ io.Writer, _ time.Duration) int {
		h.loopCalls++
		return 0
	}
	return h
}

// hasArg reports whether args holds want.
func hasArg(args []string, want string) bool {
	for _, arg := range args {
		if arg == want {
			return true
		}
	}
	return false
}

// writeBinary replaces the contents of the fake watcher binary.
func (h *portsEnableHarness) writeBinary(text string) {
	h.t.Helper()
	writeFile(h.t, h.binary, text)
}

// manualWatcher starts a real sleep process as a manually started watcher and
// writes its pid in the state folder. It is killed at the end of the test.
func (h *portsEnableHarness) manualWatcher() int {
	h.t.Helper()
	pid, done := startSleep(h.t)
	writeFile(h.t, filepath.Join(h.stateDir, "pid"), strconv.Itoa(pid)+"\n")
	h.t.Cleanup(func() {
		if alive(pid) {
			terminate(pid)
			waitExit(h.t, done)
		}
	})
	return pid
}
