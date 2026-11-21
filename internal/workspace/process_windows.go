//go:build windows

package workspace

// terminate does nothing on Windows: the port watcher and its relays are
// processes of the shell scripts of macOS and Linux, none exists here.
func terminate(pid int) {}

// alive is always false on Windows, for the same reason: there is no watcher
// process to find or to stop, only the state files to remove.
func alive(pid int) bool {
	return false
}
