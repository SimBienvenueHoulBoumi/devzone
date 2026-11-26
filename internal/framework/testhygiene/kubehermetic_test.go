package testhygiene

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// TestKubeGuardIsFirstOnPath checks that TestMain removed KUBECONFIG and put
// the failing kubectl and helm stand-ins ahead of the real tools in the PATH.
func TestKubeGuardIsFirstOnPath(t *testing.T) {
	if value := os.Getenv("KUBECONFIG"); value != "" {
		t.Fatalf("KUBECONFIG = %q, want it removed", value)
	}
	guard := filepath.Join(os.Getenv("HOME"), "bin")
	for _, name := range []string{"kubectl", "helm"} {
		path, err := exec.LookPath(name)
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if !strings.HasPrefix(filepath.ToSlash(path), filepath.ToSlash(guard)) {
			t.Fatalf("%s = %q, want a stand-in under %s", name, path, guard)
		}
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		if !strings.Contains(string(data), "is forbidden") {
			t.Fatalf("%s stand-in has no failure message: %q", name, string(data))
		}
	}
}
