package state

import (
	"testing"
)

// TestShellStateDefaultGoEquivalent checks state_default vs State.StateDefault.
func TestShellStateDefaultGoEquivalent(t *testing.T) {
	script := shellScript(t, "state.sh")
	shellPath, goPath := stateCopies(t, "")
	_, shellCode := shellState(t, script, shellPath, `state_default`)
	s := At(goPath)
	goCode := numericCode(s.StateDefault())
	compareCodes(t, "state_default", shellCode, goCode)
	compareStateBytes(t, shellPath, goPath)
	compareFiles(t, shellPath+".prev", goPath+".prev")
}
