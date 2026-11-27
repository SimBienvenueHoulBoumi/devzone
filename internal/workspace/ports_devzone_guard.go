package workspace

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

// portsDevzoneMarkerPrefix names the files and folders that identify a devzone
// folder, including its manifest .devzone.version. Why: a port watcher bound to
// a stray folder would own a separate state and never relay the real workspace.
const portsDevzoneMarkerPrefix = ".devzone."

// portsInsideDevzone reports whether folder or one of its parents holds a
// devzone marker or manifest. Why: the name of the watcher service depends on the
// folder, so a command run from anywhere else must not create another service.
func portsInsideDevzone(folder string) bool {
	dir, err := filepath.Abs(folder)
	if err != nil {
		dir = folder
	}
	for {
		entries, err := os.ReadDir(dir)
		if err == nil {
			for _, entry := range entries {
				if strings.HasPrefix(entry.Name(), portsDevzoneMarkerPrefix) {
					return true
				}
			}
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return false
		}
		dir = parent
	}
}

// portsDevzoneGuard refuses a watcher command outside a devzone folder, before
// any definition, marker, state folder or service manager call is touched. Why:
// the refusal must leave no trace in the folder the command was launched from.
// An explicit DEVZONE_PORTS_WORKSPACE_DIR accepts the command: the caller names
// its state folder itself (the service, the scripts and the tests do).
func portsDevzoneGuard(out io.Writer) bool {
	if os.Getenv("DEVZONE_PORTS_WORKSPACE_DIR") != "" {
		return false
	}
	folder := portsDevzoneFolder()
	if portsInsideDevzone(folder) {
		return false
	}
	fmt.Fprintf(out, "✖ port watcher: %s is not a devzone folder (no .devzone.* or manifest in it or its parents)\n", folder)
	return true
}
