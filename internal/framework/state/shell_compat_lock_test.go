package state

import (
	"os"
	"testing"
	"time"
)

// TestShellLockGoEquivalent checks reentrance, release and stale lock recovery.
func TestShellLockGoEquivalent(t *testing.T) {
	script := shellScript(t, "state.sh")
	// Reentrant take/release leaves no lockdir.
	shellPath, goPath := stateCopies(t, "ai=on\n")
	_, shellCode := shellState(t, script, shellPath, `state_lock_take; state_lock_take; state_lock_release; state_lock_release`)
	s := At(goPath)
	goCode := numericCode(s.lock())
	if goCode == 0 {
		goCode = numericCode(s.lock())
		s.unlock()
		s.unlock()
	}
	compareCodes(t, "lock", shellCode, goCode)
	for _, path := range []string{shellPath + ".lockdir", goPath + ".lockdir"} {
		if _, err := os.Stat(path); !os.IsNotExist(err) {
			t.Fatalf("lockdir remains: %s (%v)", path, err)
		}
	}
	// A stale lockdir (older than 30 s) is recovered, then released.
	shellPath, goPath = stateCopies(t, "ai=on\n")
	old := time.Now().Add(-31 * time.Second)
	for _, path := range []string{shellPath + ".lockdir", goPath + ".lockdir"} {
		if err := os.Mkdir(path, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.Chtimes(path, old, old); err != nil {
			t.Fatal(err)
		}
	}
	_, shellCode = shellState(t, script, shellPath, `state_lock_take; state_lock_release`)
	s = At(goPath)
	goCode = numericCode(s.lock())
	if goCode == 0 {
		s.unlock()
	}
	compareCodes(t, "stale lock", shellCode, goCode)
	for _, path := range []string{shellPath + ".lockdir", goPath + ".lockdir"} {
		if _, err := os.Stat(path); !os.IsNotExist(err) {
			t.Fatalf("lockdir remains: %s (%v)", path, err)
		}
	}
}

// TestShellLockStandaloneGoEquivalent checks state-lock.sh on its own, not
// sourced by state.sh, against Go lock/unlock.
func TestShellLockStandaloneGoEquivalent(t *testing.T) {
	script := shellScript(t, "state-lock.sh")
	shellPath, goPath := stateCopies(t, "ai=on\n")
	_, shellCode := shellState(t, script, shellPath, `state_lock_take; state_lock_release`)
	s := At(goPath)
	goCode := numericCode(s.lock())
	if goCode == 0 {
		s.unlock()
	}
	compareCodes(t, "state-lock.sh", shellCode, goCode)
	if _, err := os.Stat(shellPath + ".lockdir"); !os.IsNotExist(err) {
		t.Fatalf("shell lockdir remains: %v", err)
	}
	if _, err := os.Stat(goPath + ".lockdir"); !os.IsNotExist(err) {
		t.Fatalf("Go lockdir remains: %v", err)
	}
}
