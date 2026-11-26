//go:build !windows

package testhygiene

import (
	"fmt"
	"os"
	"path/filepath"
)

// kubeGuardBin writes stand-ins that stop with a clear error when a test
// reaches kubectl or helm instead of the fake injected in its own PATH.
func kubeGuardBin(dir string) error {
	for _, name := range []string{"kubectl", "helm"} {
		body := fmt.Sprintf("#!/bin/sh\nprintf 'devzone : test : real %s is forbidden\\n' >&2\nexit 127\n", name)
		path := filepath.Join(dir, name)
		if err := os.WriteFile(path, []byte(body), 0o755); err != nil {
			return err
		}
		if err := os.Chmod(path, 0o755); err != nil {
			return err
		}
	}
	return nil
}
