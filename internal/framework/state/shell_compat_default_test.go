package state

import (
	"path/filepath"
	"testing"
)

// TestShellStateDefaultGoEquivalent checks frozen state_default results:
// code 0, frozen default state, no .prev, taken from the shell comparison
// before state.sh was removed.
func TestShellStateDefaultGoEquivalent(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state")
	if err := At(path).StateDefault(); err != nil { // state_default
		t.Fatalf("code 1, want frozen code 0: %v", err)
	}
	assertFile(t, path, "ai=off\nkubernetes=off\ngitlab=off\n")
	assertPrev(t, path+".prev", false, "")
}
