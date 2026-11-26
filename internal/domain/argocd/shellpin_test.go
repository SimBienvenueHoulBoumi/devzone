package argocd

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// TestShellInstallerMatchesPinnedApp checks that the legacy local installer
// installs the application version declared in versions.env, so the shell
// path and the Argo CD path cannot drift apart.
func TestShellInstallerMatchesPinnedApp(t *testing.T) {
	root := filepath.Join("..", "..", "..", ".devcontainer")
	env, err := os.ReadFile(filepath.Join(root, "versions.env"))
	if err != nil {
		t.Fatal(err)
	}
	script, err := os.ReadFile(filepath.Join(root, "metrics-server.sh"))
	if err != nil {
		t.Fatal(err)
	}
	want := envValue(string(env), "METRICS_SERVER_VERSION")
	m := regexp.MustCompile(`(?m)^VERSION=(\S+)$`).FindStringSubmatch(string(script))
	if m == nil || strings.TrimSpace(m[1]) != want {
		t.Fatalf("metrics-server.sh VERSION = %v, want %q from versions.env", m, want)
	}
}
