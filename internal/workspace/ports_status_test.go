package workspace

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"testing"
)

// stoppedWatcher is the first line of every status without a live watcher.
const stoppedWatcher = "Port watcher: stopped\n"

// disabledWatcher is the automatic-start line when no definition is installed.
const disabledWatcher = "Port watcher automatic start: disabled\n"

// portsState creates a state folder holding files (slash-separated relative
// paths) and returns its path.
func portsState(t *testing.T, files map[string]string) string {
	t.Helper()
	dir := t.TempDir()
	for name, content := range files {
		writeFile(t, filepath.Join(dir, filepath.FromSlash(name)), content)
	}
	return dir
}

// portsOut runs PortsStatus on dir and returns its standard output, failing
// when the status is not 0.
func portsOut(t *testing.T, dir string) string {
	t.Helper()
	t.Setenv("DEVZONE_PORTS_WORKSPACE_DIR", dir)
	if os.Getenv("DEVZONE_PORTS_AGENT_DIR") == "" {
		t.Setenv("DEVZONE_PORTS_AGENT_DIR", filepath.Join(t.TempDir(), "agents"))
	}
	var out bytes.Buffer
	if status := PortsStatus(&out); status != 0 {
		t.Fatalf("PortsStatus status = %d, want 0", status)
	}
	return out.String()
}

func TestPortsStatusWithoutStateFolder(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "absent")
	if got := portsOut(t, dir); got != stoppedWatcher+disabledWatcher {
		t.Fatalf("output = %q, want %q", got, stoppedWatcher+disabledWatcher)
	}
}

func TestPortsStatusStaleWatcher(t *testing.T) {
	dir := portsState(t, map[string]string{"pid": "999999\n"})
	if got := portsOut(t, dir); got != stoppedWatcher+disabledWatcher {
		t.Fatalf("output = %q, want %q", got, stoppedWatcher+disabledWatcher)
	}
}

func TestPortsStatusEmptyOrNonNumericPidIsStopped(t *testing.T) {
	for _, content := range []string{"", "\n", "not-a-pid"} {
		dir := portsState(t, map[string]string{"pid": content})
		if got := portsOut(t, dir); got != stoppedWatcher+disabledWatcher {
			t.Fatalf("pid %q: output = %q, want %q", content, got, stoppedWatcher+disabledWatcher)
		}
	}
}

func TestPortsStatusRunningWatcher(t *testing.T) {
	pid, _ := startSleep(t)
	dir := portsState(t, map[string]string{"pid": strconv.Itoa(pid) + "\n"})
	want := fmt.Sprintf("Port watcher: running (pid %d)\n", pid) + disabledWatcher
	if got := portsOut(t, dir); got != want {
		t.Fatalf("output = %q, want %q", got, want)
	}
}

func TestPortsStatusListsOnlyLiveRelays(t *testing.T) {
	live, _ := startSleep(t)
	dir := portsState(t, map[string]string{
		"pid":          "999999\n",
		"relays/5432":  strconv.Itoa(live) + "\n",
		"relays/8080":  "999999\n",
		"relays/abc":   "not-a-pid\n",
		"relays/.6000": strconv.Itoa(live) + "\n",
	})
	want := stoppedWatcher + disabledWatcher + "  127.0.0.1:5432 relayed\n"
	if got := portsOut(t, dir); got != want {
		t.Fatalf("output = %q, want %q", got, want)
	}
}

func TestPortsStatusReportsTakenPortsInOrder(t *testing.T) {
	dir := portsState(t, map[string]string{"taken/3000": "", "taken/1000": ""})
	want := stoppedWatcher + disabledWatcher +
		"  ⚠ port 1000 already in use on the workstation, not relayed\n" +
		"  ⚠ port 3000 already in use on the workstation, not relayed\n"
	if got := portsOut(t, dir); got != want {
		t.Fatalf("output = %q, want %q", got, want)
	}
}

func TestPortsStatusRelayedApplication(t *testing.T) {
	live, _ := startSleep(t)
	dir := portsState(t, map[string]string{
		"apps/default.web.3000": "3000",
		"relays/3000":           strconv.Itoa(live) + "\n",
	})
	want := stoppedWatcher + disabledWatcher + "  127.0.0.1:3000 relayed\n" +
		"  http://127.0.0.1:3000  default/web:3000\n"
	if got := portsOut(t, dir); got != want {
		t.Fatalf("output = %q, want %q", got, want)
	}
}

func TestPortsStatusApplicationWithoutReadyPod(t *testing.T) {
	dir := portsState(t, map[string]string{
		"apps/team.api.9000":         "9000",
		"no-ready-pod/team.api.9000": "",
		"no-ready-pod/gone.8000":     "",
	})
	want := stoppedWatcher + disabledWatcher + "  http://127.0.0.1:9000  team/api:9000  no ready pod\n"
	if got := portsOut(t, dir); got != want {
		t.Fatalf("output = %q, want %q", got, want)
	}
}

func TestPortsStatusApplicationNameWithSeveralDots(t *testing.T) {
	live, _ := startSleep(t)
	dir := portsState(t, map[string]string{
		"apps/team.guestbook.ui.80": "8080",
		"relays/8080":               strconv.Itoa(live) + "\n",
	})
	want := stoppedWatcher + disabledWatcher + "  127.0.0.1:8080 relayed\n" +
		"  http://127.0.0.1:8080  team/guestbook:ui.80\n"
	if got := portsOut(t, dir); got != want {
		t.Fatalf("output = %q, want %q", got, want)
	}
}

func TestPortsStatusSortsRelayNamesLexicographically(t *testing.T) {
	live, _ := startSleep(t)
	pid := strconv.Itoa(live) + "\n"
	dir := portsState(t, map[string]string{
		"relays/1000": pid,
		"relays/200":  pid,
		"relays/30":   pid,
	})
	want := stoppedWatcher + disabledWatcher +
		"  127.0.0.1:1000 relayed\n" +
		"  127.0.0.1:200 relayed\n" +
		"  127.0.0.1:30 relayed\n"
	if got := portsOut(t, dir); got != want {
		t.Fatalf("output = %q, want %q", got, want)
	}
}

func TestPortsStatusIgnoresHiddenNames(t *testing.T) {
	live, _ := startSleep(t)
	pid := strconv.Itoa(live) + "\n"
	dir := portsState(t, map[string]string{
		"relays/.5432":            pid,
		"relays/3000":             pid,
		"taken/.3000":             "",
		"apps/.default.web.3000":  "3000",
		"no-ready-pod/.team.9000": "",
	})
	want := stoppedWatcher + disabledWatcher + "  127.0.0.1:3000 relayed\n"
	if got := portsOut(t, dir); got != want {
		t.Fatalf("output = %q, want %q", got, want)
	}
}
