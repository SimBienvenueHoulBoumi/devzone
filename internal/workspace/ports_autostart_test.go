//go:build !windows

package workspace

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

// TestPortsWatcherUpToDateTracksTheBinary checks that the copy of the watcher
// is reported current only while it holds the running program, which is what
// lets an automatic start skip the service manager once installed.
func TestPortsWatcherUpToDateTracksTheBinary(t *testing.T) {
	h := newPortsEnableHarness(t)
	if PortsWatcherUpToDate() {
		t.Fatal("a binary without a copy must be reported as needing installation")
	}
	var out, errOut bytes.Buffer
	if code := PortsEnable(&out, &errOut); code != 0 {
		t.Fatalf("status = %d, err = %q", code, errOut.String())
	}
	if !PortsWatcherUpToDate() {
		t.Fatal("enable must install the current binary")
	}
	h.writeBinary("binary v2\n")
	if PortsWatcherUpToDate() {
		t.Fatal("a replaced binary must make the installed copy out of date")
	}
	out.Reset()
	errOut.Reset()
	if code := PortsEnable(&out, &errOut); code != 0 {
		t.Fatalf("status = %d, err = %q", code, errOut.String())
	}
	if !PortsWatcherUpToDate() {
		t.Fatal("enable must reinstall the current binary")
	}
}

// TestPortsWatcherUpToDateWithoutBinary reports a missing program as out of
// date rather than claiming an installation that cannot serve the watcher.
func TestPortsWatcherUpToDateWithoutBinary(t *testing.T) {
	h := newPortsEnableHarness(t)
	if err := os.Remove(h.binary); err != nil {
		t.Fatal(err)
	}
	if PortsWatcherUpToDate() {
		t.Fatal("a missing binary must not be reported as up to date")
	}
}

// TestPortsRefusalIsPerFolder checks that a refusal stays in the devzone folder
// where it was expressed, is not written outside a devzone folder and is erased
// by ports enable.
func TestPortsRefusalIsPerFolder(t *testing.T) {
	first := filepath.Join(t.TempDir(), "first")
	second := filepath.Join(t.TempDir(), "second")
	for _, folder := range []string{first, second} {
		if err := os.MkdirAll(filepath.Join(folder, ".devcontainer"), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("HOME", t.TempDir())
	t.Setenv("DEVZONE_ROOT", first)
	if PortsRefused() {
		t.Fatal("a fresh folder must not be refused")
	}
	MemorizePortsRefusal()
	if !PortsRefused() {
		t.Fatal("memorised refusal was not read back")
	}
	t.Setenv("DEVZONE_ROOT", second)
	if PortsRefused() {
		t.Fatal("the refusal of another folder must not apply here")
	}
	MemorizePortsRefusal()
	t.Setenv("DEVZONE_ROOT", filepath.Join(t.TempDir(), "outside"))
	MemorizePortsRefusal()
	if _, err := os.Stat(filepath.Join(os.Getenv("DEVZONE_ROOT"), portsRefusalName)); !os.IsNotExist(err) {
		t.Fatalf("marker written outside a devzone folder: %v", err)
	}
	t.Setenv("DEVZONE_ROOT", first)
	ForgetPortsRefusal()
	if PortsRefused() {
		t.Fatal("ForgetPortsRefusal did not clear the marker")
	}
}
