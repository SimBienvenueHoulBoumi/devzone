//go:build !windows

package workspace

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestPortsScriptHasNoAutomaticStart checks that the shell original stays
// limited to the watcher: the automatic start and its status line belong to Go,
// so the parity tests only have to exclude that one status line.
func TestPortsScriptHasNoAutomaticStart(t *testing.T) {
	data, err := os.ReadFile(filepath.FromSlash(portsScript))
	if err != nil {
		t.Fatal(err)
	}
	text := string(data)
	for _, forbidden := range []string{"pw_instance_name", "pw_agent_enabled", "Port watcher automatic start:"} {
		if strings.Contains(text, forbidden) {
			t.Fatalf("shell original still holds %q", forbidden)
		}
	}
}
