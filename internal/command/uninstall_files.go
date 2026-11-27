package command

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
)

// stateFileName is the state file of the folder: one line per module, the
// instance cluster and the image and volume of the host.
const stateFileName = ".devzone.state"

// devzoneStateFiles are the files of the folder the uninstall removes once the
// removal succeeded: the log, the state and the module state. The manifest
// (.devzone.version) and the backups (.devzone.backup/) are kept.
var devzoneStateFiles = []string{".devzone.log", stateFileName, ".devzone.modules"}

// listDevzoneFiles returns the state files of the folder that exist. workspace/
// is never in the list.
func listDevzoneFiles(root string) []string {
	var out []string
	for _, name := range devzoneStateFiles {
		path := filepath.Join(root, name)
		if _, err := os.Stat(path); err == nil {
			out = append(out, path)
		}
	}
	return out
}

// removeStateFiles removes the given state files. It returns 1 when one could
// not be removed; the others are still removed.
func removeStateFiles(files []string, out, errOut io.Writer) int {
	status := 0
	for _, f := range files {
		if err := os.RemoveAll(f); err != nil {
			fmt.Fprintf(errOut, "✖ file %s: %v\n", filepath.Base(f), err)
			status = 1
			continue
		}
		fmt.Fprintf(out, "✔ file removed: %s\n", filepath.Base(f))
	}
	return status
}
