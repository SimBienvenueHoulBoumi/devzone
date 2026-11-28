package argocd

import (
	"strings"
	"testing"
)

// TestFlatKeyIsReported checks that a dotted key at the top level is flagged:
// Helm does not expand it, so the setting would silently do nothing.
func TestFlatKeyIsReported(t *testing.T) {
	got := ValidateWorkspaceValues([]byte("livenessProbe.thresholdPercent: 90\n"))
	if len(got) != 1 || !strings.Contains(got[0], "flat key") {
		t.Fatalf("flat key not reported: %v", got)
	}
}

// TestNestedKeysAreAccepted checks the nested form that Helm reads.
func TestNestedKeysAreAccepted(t *testing.T) {
	data := "livenessProbe:\n  thresholdPercent: 90\nresources:\n  limits:\n    memory: 6Gi\n"
	if got := ValidateWorkspaceValues([]byte(data)); len(got) != 0 {
		t.Fatalf("valid nested file reported: %v", got)
	}
}
