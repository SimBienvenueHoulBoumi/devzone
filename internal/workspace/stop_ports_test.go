package workspace

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"testing"
	"time"
)

// writeFile writes content to path, creating its folders
func writeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

// exists reports whether path exists
func exists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

// startSleep starts a real process that the port watcher can stop. Its exit is
// reaped in the background, so that a stopped process is not seen as alive.
func startSleep(t *testing.T) (int, <-chan error) {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("the test starts a sleep process")
	}
	cmd := exec.Command("sleep", "60")
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	return cmd.Process.Pid, done
}

// waitExit fails the test unless the process reaped on done has exited in time
func waitExit(t *testing.T, done <-chan error) {
	t.Helper()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("the process was not stopped")
	}
}

func TestStopPortsStopsWatcherAndRelays(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("DEVZONE_PORTS_WORKSPACE_DIR", dir)
	watcher, watcherDone := startSleep(t)
	relay, relayDone := startSleep(t)
	writeFile(t, filepath.Join(dir, "pid"), strconv.Itoa(watcher)+"\n")
	writeFile(t, filepath.Join(dir, "verrou", "lock"), "")
	writeFile(t, filepath.Join(dir, "relais", "5432"), strconv.Itoa(relay)+"\n")
	writeFile(t, filepath.Join(dir, "pris", "5432"), "")
	writeFile(t, filepath.Join(dir, "relais", "8080"), "999999\n")
	writeFile(t, filepath.Join(dir, "pris", "8080"), "")

	stopPorts()

	waitExit(t, watcherDone)
	waitExit(t, relayDone)
	for _, path := range []string{"pid", "verrou", "relais/5432", "pris/5432", "relais/8080", "pris/8080"} {
		if exists(filepath.Join(dir, path)) {
			t.Fatalf("%s still exists after stopPorts", path)
		}
	}
}

func TestStopPortsWithoutStateFolder(t *testing.T) {
	t.Setenv("DEVZONE_PORTS_WORKSPACE_DIR", filepath.Join(t.TempDir(), "absent"))
	stopPorts()
}

func TestStopPortsKeepsOtherFiles(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("DEVZONE_PORTS_WORKSPACE_DIR", dir)
	writeFile(t, filepath.Join(dir, "journal.log"), "log\n")
	stopPorts()
	if !exists(filepath.Join(dir, "journal.log")) {
		t.Fatal("the journal was removed: ports_stop removes only the lock, the pid and the relays")
	}
}

func TestPortsDirFromEnvironment(t *testing.T) {
	t.Setenv("DEVZONE_PORTS_WORKSPACE_DIR", "/custom/ports")
	if got := portsDir(); got != "/custom/ports" {
		t.Fatalf("portsDir() = %q, want the environment value", got)
	}
}

func TestPortsDirFromShellFolder(t *testing.T) {
	t.Setenv("DEVZONE_PORTS_WORKSPACE_DIR", "")
	t.Setenv("PWD", "/work/devzone")
	if got := portsDir(); got != "/work/devzone/.devzone.workspace-ports" {
		t.Fatalf("portsDir() = %q, want the shell folder state", got)
	}
}

func TestAliveRefusesNonProcesses(t *testing.T) {
	for _, pid := range []int{0, -1} {
		if alive(pid) {
			t.Fatalf("alive(%d) = true, want false", pid)
		}
	}
	if readPid(filepath.Join(t.TempDir(), "absent")) != 0 {
		t.Fatal("readPid of a missing file is not 0")
	}
}
