package testhygiene

import (
	"os"
	"path/filepath"
)

// cleanKubeEnvironment removes the variables that select a real kubeconfig and
// prepends a folder whose kubectl and helm fail loudly, so a test that starts
// either tool by accident cannot reach a cluster and reports the cause.
func cleanKubeEnvironment(dir string) error {
	if err := os.Unsetenv("KUBECONFIG"); err != nil {
		return err
	}
	bin := filepath.Join(dir, "bin")
	if err := os.MkdirAll(bin, 0o755); err != nil {
		return err
	}
	if err := kubeGuardBin(bin); err != nil {
		return err
	}
	return os.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
}
