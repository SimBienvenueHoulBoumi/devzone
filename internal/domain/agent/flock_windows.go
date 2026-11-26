//go:build windows

package agent

import "os"

// flockWait is a no-op success on windows (no flock binary; mkdir is the guard).
func flockWait(f *os.File, sec int) bool { return true }

// flockUnlock is a no-op on windows.
func flockUnlock(f *os.File) {}
