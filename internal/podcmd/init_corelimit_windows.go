//go:build windows

package podcmd

// setCoreLimit keeps the Windows build complete; the workspace pod runs on
// Linux, where the real resource limit is lowered before the init steps.
func setCoreLimit() {}
