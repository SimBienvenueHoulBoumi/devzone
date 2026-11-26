//go:build !windows

package workspace

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// TestPortsEnableReplacesARunningWatcherCopy checks that a second enable can
// replace the copy of the watcher while a managed process still executes it: a
// write in place is refused by Linux (text file busy), so enable must install a
// new file instead. The process is real and is killed at the end of the test.
func TestPortsEnableReplacesARunningWatcherCopy(t *testing.T) {
	h := newPortsEnableHarness(t)
	sleep, err := exec.LookPath("sleep")
	if err != nil {
		t.Skip("the test needs a sleep program")
	}
	program, err := os.ReadFile(sleep)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(h.copyPath), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(h.copyPath, program, 0o755); err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(h.copyPath, "60")
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	t.Cleanup(func() {
		_ = cmd.Process.Kill()
		select {
		case <-done:
		case <-time.After(5 * time.Second):
			t.Error("the running copy was not killed")
		}
	})
	if !alive(cmd.Process.Pid) {
		t.Fatal("the process of the running copy is not alive")
	}

	h.writeBinary("binary v2\n")
	var out, errOut bytes.Buffer
	if code := PortsEnable(&out, &errOut); code != 0 {
		t.Fatalf("enable with a running copy = %d, err = %q", code, errOut.String())
	}
	data, err := os.ReadFile(h.copyPath)
	if err != nil || string(data) != "binary v2\n" {
		t.Fatalf("copy = %q, err = %v, want the new program", data, err)
	}
	entries, err := os.ReadDir(filepath.Dir(h.copyPath))
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), ".devzone-watcher-") {
			t.Fatalf("temporary file left: %s", entry.Name())
		}
	}
}

// TestPortsCopyWatcherKeepsAnIdenticalBinary checks that installing the same
// contents leaves the existing file alone: no replacement and no new inode.
func TestPortsCopyWatcherKeepsAnIdenticalBinary(t *testing.T) {
	dir := t.TempDir()
	exe := filepath.Join(dir, "source")
	path := filepath.Join(dir, "bin", "devzone")
	writeFile(t, exe, "binary v1\n")
	installed, err := copyWatcher(exe, path)
	if err != nil || installed {
		t.Fatalf("first install = %v, %v, want no replacement of an absent file", installed, err)
	}
	before, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if before.Mode()&0o111 == 0 {
		t.Fatalf("copy is not executable: %v", before.Mode())
	}
	installed, err = copyWatcher(exe, path)
	if err != nil || installed {
		t.Fatalf("second install = %v, %v, want no replacement", installed, err)
	}
	after, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if !os.SameFile(before, after) || !before.ModTime().Equal(after.ModTime()) {
		t.Fatal("an identical copy was rewritten")
	}
}

// TestPortsCopyWatcherLeavesNoTempOnFailure checks that a failed rename of the
// temporary file leaves no stray file next to the destination.
func TestPortsCopyWatcherLeavesNoTempOnFailure(t *testing.T) {
	dir := t.TempDir()
	exe := filepath.Join(dir, "source")
	writeFile(t, exe, "binary v1\n")
	blocked := filepath.Join(dir, "devzone")
	if err := os.Mkdir(blocked, 0o755); err != nil {
		t.Fatal(err)
	}
	if _, err := copyWatcher(exe, blocked); err == nil {
		t.Fatal("a rename onto a directory succeeded")
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), ".devzone-watcher-") {
			t.Fatalf("temporary file left after failure: %s", entry.Name())
		}
	}
}
