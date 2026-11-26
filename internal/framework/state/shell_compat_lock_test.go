package state

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// TestShellLockGoEquivalent checks frozen lock results: reentrance, release
// leaves no lockdir, and stale lockdir (older than 30 s) recovered, taken from
// the shell comparison before state.sh was removed.
func TestShellLockGoEquivalent(t *testing.T) {
	// Reentrant take/release leaves no lockdir (code 0).
	path := filepath.Join(t.TempDir(), "state")
	writeStateFile(t, path, "ai=on\n")
	s := At(path)
	if err := s.lock(); err != nil { // state_lock_take
		t.Fatalf("lock code 1, want frozen code 0: %v", err)
	}
	if err := s.lock(); err != nil { // state_lock_take again
		t.Fatalf("reentrant lock code 1, want frozen code 0: %v", err)
	}
	s.unlock() // state_lock_release
	s.unlock() // state_lock_release
	if _, err := os.Stat(path + ".lockdir"); !os.IsNotExist(err) {
		t.Fatalf("lockdir remains (%v)", err)
	}

	// A stale lockdir (older than 30 s) is recovered, then released.
	stalePath := filepath.Join(t.TempDir(), "state")
	writeStateFile(t, stalePath, "ai=on\n")
	old := time.Now().Add(-31 * time.Second)
	if err := os.Mkdir(stalePath+".lockdir", 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(stalePath+".lockdir", old, old); err != nil {
		t.Fatal(err)
	}
	s = At(stalePath)
	if err := s.lock(); err != nil { // state_lock_take on stale lockdir
		t.Fatalf("stale lock code 1, want frozen code 0: %v", err)
	}
	s.unlock() // state_lock_release
	if _, err := os.Stat(stalePath + ".lockdir"); !os.IsNotExist(err) {
		t.Fatalf("lockdir remains (%v)", err)
	}
}

// TestShellLockStandaloneGoEquivalent checks frozen standalone lock results
// (formerly state-lock.sh on its own): take/release leaves no lockdir and code
// 0, taken from the shell comparison before state-lock.sh was removed.
func TestShellLockStandaloneGoEquivalent(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state")
	writeStateFile(t, path, "ai=on\n")
	s := At(path)
	if err := s.lock(); err != nil { // state_lock_take
		t.Fatalf("lock code 1, want frozen code 0: %v", err)
	}
	s.unlock() // state_lock_release
	if _, err := os.Stat(path + ".lockdir"); !os.IsNotExist(err) {
		t.Fatalf("lockdir remains (%v)", err)
	}
}
