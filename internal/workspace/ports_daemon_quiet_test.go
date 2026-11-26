//go:build !windows

package workspace

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// portsDaemonHelperEnv switches TestPortsDaemonHelperUsage into a child process
// that imitates launchctl printing its usage text and failing: no real
// service manager is started.
const portsDaemonHelperEnv = "DEVZONE_PORTS_DAEMON_HELPER"

// TestPortsDaemonHelperUsage is the child process of the quiet tests. Without
// the environment variable it does nothing.
func TestPortsDaemonHelperUsage(t *testing.T) {
	if os.Getenv(portsDaemonHelperEnv) == "" {
		return
	}
	fmt.Println("Usage: launchctl bootout <domain-target> <service-target>")
	os.Exit(1)
}

// runHelperDaemon runs the usage helper through runDaemon with quiet set as
// given, and returns its status and what reached the standard output.
func runHelperDaemon(t *testing.T, quiet bool) (int, string) {
	t.Helper()
	t.Setenv(portsDaemonHelperEnv, "1")
	stdout := filepath.Join(t.TempDir(), "stdout")
	file, err := os.Create(stdout)
	if err != nil {
		t.Fatal(err)
	}
	old := os.Stdout
	os.Stdout = file
	status := runDaemon(os.Args[0], quiet, "-test.run=^TestPortsDaemonHelperUsage$")
	os.Stdout = old
	_ = file.Close()
	data, err := os.ReadFile(stdout)
	if err != nil {
		t.Fatal(err)
	}
	return status, string(data)
}

// TestPortsDaemonQuietPrintsNoUsage checks that a quiet service manager call
// that fails prints nothing, while an ordinary call still shows its output.
func TestPortsDaemonQuietPrintsNoUsage(t *testing.T) {
	status, out := runHelperDaemon(t, true)
	if status != 1 || out != "" {
		t.Fatalf("quiet call: status = %d, stdout = %q", status, out)
	}
	status, out = runHelperDaemon(t, false)
	if status != 1 || !strings.Contains(out, "Usage: launchctl") {
		t.Fatalf("loud call: status = %d, stdout = %q", status, out)
	}
}

// TestPortsEnableDarwinBootoutIsQuiet checks that the unload before the
// bootstrap is the only quiet call of enable, and that the bootstrap is not.
func TestPortsEnableDarwinBootoutIsQuiet(t *testing.T) {
	h := newPortsEnableHarness(t)
	portsPlatform = "darwin"
	var out, errOut bytes.Buffer
	if code := PortsEnable(&out, &errOut); code != 0 {
		t.Fatalf("enable = %d, err = %q", code, errOut.String())
	}
	if len(h.calls) != 2 || h.calls[0].args[0] != "bootout" || !h.calls[0].quiet {
		t.Fatalf("first call = %+v, want a quiet bootout", h.calls)
	}
	if h.calls[1].args[0] != "bootstrap" || h.calls[1].quiet {
		t.Fatalf("second call = %+v, want a loud bootstrap", h.calls[1])
	}
}
