package workspace

import (
	"bytes"
	"os"
)

// PortsWatcherUpToDate reports whether the copy of the watcher used by the
// automatic start holds the same program as the running devzone binary. A
// definition with a current copy needs no call to the service manager, which
// keeps every user command fast once the installation is in place.
func PortsWatcherUpToDate() bool {
	exe, err := watcherExecutable()
	if err != nil {
		return false
	}
	source, err := os.ReadFile(exe)
	if err != nil {
		return false
	}
	target, err := os.ReadFile(portsWatcherCopyPath())
	if err != nil {
		return false
	}
	return bytes.Equal(source, target)
}
