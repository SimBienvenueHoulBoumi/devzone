//go:build windows

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
		body := fmt.Sprintf("@echo off\necho devzone : test : real %s is forbidden 1>&2\nexit /b 127\n", name)
		path := filepath.Join(dir, name+".bat")
		if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
			return err
		}
	}
	return nil
}
