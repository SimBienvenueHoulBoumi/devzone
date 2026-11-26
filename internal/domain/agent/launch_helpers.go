package agent

import (
	"context"
	"os"
	"path/filepath"
)

func orNone(s string) string {
	if s == "" {
		return "none"
	}
	return s
}

func contains(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

func fileReadable(p string) bool {
	f, err := os.Open(p)
	if err != nil {
		return false
	}
	f.Close()
	return true
}

func absFile(p string) string {
	abs, err := filepath.Abs(p)
	if err != nil {
		return p
	}
	if dir, err := filepath.Abs(filepath.Dir(p)); err == nil {
		if resolved, err := filepath.EvalSymlinks(dir); err == nil {
			return filepath.Join(resolved, filepath.Base(p))
		}
	}
	return abs
}

// aiEnabled: `devzone is-enabled ai` (shell) code 0.
func aiEnabled(ctx context.Context, r Runner, devcontainerDir string) bool {
	if r == nil {
		return false
	}
	script := filepath.Join(devcontainerDir, "devzone")
	res, err := r.Run(ctx, "bash", []string{script, "is-enabled", "ai"}, Opts{})
	return err == nil && res.Code == 0
}
