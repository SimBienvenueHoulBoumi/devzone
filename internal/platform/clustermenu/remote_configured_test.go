package clustermenu

import (
	"strings"
	"testing"
)

// TestRemoteConfiguredServicesContextIsLocal: the services context chosen with
// DEVZONE_CONTEXT is a local context like "devzone", so it is never offered as a
// remote cluster, while an unrelated context is.
func TestRemoteConfiguredServicesContextIsLocal(t *testing.T) {
	t.Setenv("DEVZONE_CONTEXT", "autre")
	f := newFixture("1\n\n", true)
	f.contexts("autre", "prod-eks")
	f.server("autre", "https://203.0.113.9:6443")
	f.server("prod-eks", "https://203.0.113.5:6443")
	f.menu.Offer()
	out := f.out.String()
	if !strings.Contains(out, "  1) prod-eks (remote)") {
		t.Fatalf("remote context not offered: %q", out)
	}
	if strings.Contains(out, "autre (remote)") {
		t.Fatalf("configured services context offered as remote: %q", out)
	}
}
