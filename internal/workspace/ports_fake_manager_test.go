package workspace

import (
	"bytes"
	"io"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

// portsFakeManager is a service manager for launchctl, systemctl or schtasks.
// Why: a test must check load and reload without touching a real service or
// putting a fake program in the PATH.
type portsFakeManager struct {
	t        *testing.T
	platform string
	loaded   bool
	calls    []portsDaemonCall
}

// newPortsFakeManager injects temporary folders and every function the
// automatic start uses. Why: the same test runs on macOS, Linux and Windows
// without a real binary, a real watcher or a hard-coded system path.
func newPortsFakeManager(t *testing.T, platform string) *portsFakeManager {
	t.Helper()
	base := t.TempDir()
	root := filepath.Join(base, "devzone")
	writeFile(t, filepath.Join(root, ".devzone.modules"), "")
	binary := filepath.Join(base, "bin", "devzone")
	writeFile(t, binary, "fake watcher\n")
	values := map[string]string{
		"DEVZONE_ROOT":                 root,
		"DEVZONE_INSTANCE":             "alpha",
		"DEVZONE_PORTS_AGENT_DIR":      filepath.Join(base, "agents"),
		"DEVZONE_PORTS_WORKSPACE_DIR":  filepath.Join(base, "state"),
		"HOME":                         filepath.Join(base, "home"),
		"XDG_CONFIG_HOME":              filepath.Join(base, "config"),
		"XDG_CACHE_HOME":               filepath.Join(base, "cache"),
		"LOCALAPPDATA":                 filepath.Join(base, "local"),
		"KUBECONFIG":                   "",
		"BATS_TEST_TMPDIR":             "",
		"DEVZONE_PORTS_WORKSPACE_REAL": "yes",
	}
	for key, value := range values {
		t.Setenv(key, value)
	}
	m := &portsFakeManager{t: t, platform: platform, loaded: true}
	oldPlatform, oldDaemon := portsPlatform, portsDaemon
	oldLookPath, oldRunner := portsLookPath, portsRunner
	oldExecutable, oldKubectl := watcherExecutable, portsKubectlPath
	oldLoop := portsLoopRunner
	t.Cleanup(func() {
		portsPlatform, portsDaemon = oldPlatform, oldDaemon
		portsLookPath, portsRunner = oldLookPath, oldRunner
		watcherExecutable, portsKubectlPath = oldExecutable, oldKubectl
		portsLoopRunner = oldLoop
	})
	portsPlatform = platform
	portsDaemon = runDaemon
	portsLookPath = func(tool string) (string, error) { return filepath.Join(base, "tools", tool), nil }
	portsRunner = m.run
	watcherExecutable = func() (string, error) { return binary, nil }
	portsKubectlPath = func(string) (string, error) { return filepath.Join(base, "bin", "kubectl"), nil }
	portsLoopRunner = func(io.Writer, io.Writer, time.Duration) int { return 0 }
	return m
}

// run records one service manager call and answers as the platform would: a
// query tells whether the service is loaded, a load registers it again.
func (m *portsFakeManager) run(cmd *exec.Cmd) int {
	args := append([]string(nil), cmd.Args[1:]...)
	m.calls = append(m.calls, portsDaemonCall{
		tool:  filepath.Base(cmd.Path),
		quiet: cmd.Stdout == nil,
		args:  args,
	})
	if len(args) == 0 {
		return 1
	}
	switch {
	case m.isQueryCall(args):
		if m.loaded {
			return 0
		}
		return 1
	case m.isLoadCall(args):
		m.loaded = true
		return 0
	}
	return 0
}

// definition returns the path of the definition file of this platform.
func (m *portsFakeManager) definition() string {
	return filepath.Join(portsAgentDir(), portsAgentName()+"."+portsAgentExt())
}

// install writes a current definition through ports enable and clears the
// recorded calls, so a test starts from a loaded automatic start.
func (m *portsFakeManager) install() {
	m.t.Helper()
	var out, errOut bytes.Buffer
	if code := PortsEnable(&out, &errOut); code != 0 {
		m.t.Fatalf("enable = %d, err = %q", code, errOut.String())
	}
	if !portsAgentExists() {
		m.t.Fatal("enable wrote no definition")
	}
	m.reset()
}

// reset forgets the calls recorded so far without changing the loaded state.
func (m *portsFakeManager) reset() {
	m.calls = nil
}

// isQueryCall reports whether args ask for the load state of the watcher.
func (m *portsFakeManager) isQueryCall(args []string) bool {
	switch m.platform {
	case "darwin":
		return args[0] == "print"
	case "windows":
		return args[0] == "/Query"
	}
	return portsHasArg(args, "is-active")
}

// portsHasArg reports whether args holds want. Why: the fake manager must be
// usable in tests compiled for Windows, where the helper of the Linux tests is
// not present.
func portsHasArg(args []string, want string) bool {
	for _, arg := range args {
		if arg == want {
			return true
		}
	}
	return false
}

// isLoadCall reports whether args register the watcher in the service manager.
func (m *portsFakeManager) isLoadCall(args []string) bool {
	switch m.platform {
	case "darwin":
		return args[0] == "bootstrap"
	case "windows":
		return args[0] == "/Create"
	}
	return args[0] == "--user" && portsHasArg(args, "enable")
}

// runPortsCommand runs one of the three watcher commands and returns its code.
func runPortsCommand(t *testing.T, command string, out, errOut io.Writer) int {
	t.Helper()
	switch command {
	case "enable":
		return PortsEnable(out, errOut)
	case "start":
		return PortsStart(out, errOut)
	}
	return PortsStatus(out)
}
