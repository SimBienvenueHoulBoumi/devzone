package podcmd

import (
	"io"
	"strings"
	"testing"
)

// TestCatalogRegistered checks that the catalog and its watcher are handled by
// the pod binary and listed among the ported commands.
func TestCatalogRegistered(t *testing.T) {
	for _, name := range []string{"catalog", "catalog-watcher"} {
		if _, ok := Registry.Lookup(name); !ok {
			t.Fatalf("%s not registered", name)
		}
		if code := Run([]string{"handles", name}, io.Discard, io.Discard); code != 0 {
			t.Fatalf("handles %s: code %d, want 0", name, code)
		}
	}
	joined := "," + strings.Join(Ported(), ",") + ","
	for _, name := range []string{",catalog,", ",catalog-watcher,"} {
		if !strings.Contains(joined, name) {
			t.Fatalf("Ported misses %s: %v", name, Ported())
		}
	}
}
