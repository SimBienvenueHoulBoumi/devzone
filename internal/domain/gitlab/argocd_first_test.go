package gitlab

import (
	"strings"
	"testing"
)

// TestFirstInstallDeploysWithoutPruning checks that a first install deploys by
// itself yet never prunes, while an adopted Application keeps manual sync.
func TestFirstInstallDeploysWithoutPruning(t *testing.T) {
	first := applicationManifestWithRelease("ns", "https://example.invalid/d.git", "v1", "gitlab", true)
	for _, want := range []string{"    automated:\n      prune: false\n      selfHeal: false\n", "      - PruneLast=true"} {
		if !strings.Contains(first, want) {
			t.Errorf("first install lacks %q:\n%s", want, first)
		}
	}
	if strings.Contains(first, "prune: true") || strings.Contains(first, "selfHeal: true") {
		t.Errorf("first install must never prune or self-heal:\n%s", first)
	}
	adopted := applicationManifestWithRelease("ns", "https://example.invalid/d.git", "v1", "gitlab", false)
	if strings.Contains(adopted, "automated:") {
		t.Errorf("an existing Application keeps manual sync:\n%s", adopted)
	}
}
