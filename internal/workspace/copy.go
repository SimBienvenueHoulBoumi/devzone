package workspace

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
)

// Messages of copy-to and copy-from without a folder argument, as copy_to and
// copy_from print them in manage/workspace.sh.
const (
	copyToUsage   = "✖ provide a workstation folder: devzone workspace copy-to <folder>"
	copyFromUsage = "✖ provide a workstation folder: devzone workspace copy-from <folder>"
)

// CopyTo copies a workstation folder to the projects folder of the pod, under
// its own name, with kubectl cp, as copy_to in manage/workspace.sh does. It
// returns 1 (message on errOut) when no folder is given, when the folder is not
// a directory, or when the pod holds a clone of another remote (see copyGuard).
// Otherwise it returns the status of kubectl cp, or 127 when kubectl cannot
// start. origin gives the remote of the workstation folder.
func CopyTo(r Runner, origin OriginFunc, folder string, out, errOut io.Writer) int {
	if folder == "" {
		fmt.Fprintln(errOut, copyToUsage)
		return 1
	}
	if !isDir(folder) {
		fmt.Fprintf(errOut, "✖ folder not found: %s\n", folder)
		return 1
	}
	folder = absoluteFolder(folder)
	if !copyGuard(r, origin, folder, errOut) {
		return 1
	}
	return runCopy(r, folder, pod+":"+projectsDir+"/"+filepath.Base(folder), out, errOut)
}

// CopyFrom copies a project of the projects folder of the pod to the workstation
// folder of the same name, with kubectl cp, as copy_from in manage/workspace.sh
// does. The folder may not exist yet; when it does, it is made absolute, so
// "copy-from ." takes the name of the current folder. It returns 1 when no
// folder is given, otherwise the status of kubectl cp (127 when kubectl cannot
// start).
func CopyFrom(r Runner, folder string, out, errOut io.Writer) int {
	if folder == "" {
		fmt.Fprintln(errOut, copyFromUsage)
		return 1
	}
	folder = absoluteFolder(folder)
	return runCopy(r, pod+":"+projectsDir+"/"+filepath.Base(folder), folder, out, errOut)
}

// runCopy runs kubectl cp from src to dst, with the context and the namespace
// of the workspace (see contextFlag). A kubectl that cannot start gives 127.
func runCopy(r Runner, src, dst string, out, errOut io.Writer) int {
	args := append(contextFlag(r), "cp", src, dst, "--namespace", namespace, "-c", container)
	status, err := r.Kubectl(args, nil, out, errOut)
	if err != nil {
		fmt.Fprintf(errOut, "devzone: cannot start kubectl: %v\n", err)
		return notStarted
	}
	return status
}

// absoluteFolder returns the absolute path of folder when it is a directory, as
// "cd folder && pwd" gives it in manage/workspace.sh. Otherwise it returns folder
// as given, which is what copy-from keeps for a folder not yet created.
func absoluteFolder(folder string) string {
	if !isDir(folder) {
		return folder
	}
	abs, err := filepath.Abs(folder)
	if err != nil {
		return folder
	}
	return abs
}

// isDir reports whether path is a directory (a symbolic link to one included).
func isDir(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.IsDir()
}
