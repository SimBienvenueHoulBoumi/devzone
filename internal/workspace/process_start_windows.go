//go:build windows

package workspace

import (
	"errors"
	"os/exec"
)

// startDetached cannot start a relay on Windows: like terminate and alive, the
// port watcher belongs to macOS and Linux, so the caller gets an explicit error.
func startDetached(cmd *exec.Cmd) (int, error) {
	return 0, errors.New("the port watcher is not supported on Windows")
}
