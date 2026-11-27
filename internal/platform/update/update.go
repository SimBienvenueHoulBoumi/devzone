// Package update brings a devzone folder to the files of the installed package:
// the Go port of manage/scripts/devzone-update.sh (#349, #884). The steps keep
// the order of the shell version: the folder and package versions are compared,
// the files the user changed are listed and asked about, every file that is
// replaced or removed is backed up, then the package is copied, the old package
// is removed, the manifest is written and the rebuild is offered.
package update

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/platform/manifest"
)

// Commander runs an external command in dir (the process folder when empty), with
// its output going to out and errOut, and returns its exit status. The rebuild and
// the port watcher go through it, so a test replaces them with a fake.
type Commander func(dir string, out, errOut io.Writer, name string, args ...string) int

// Options carries what one update needs: the folders, the answers given on the
// command line, the terminal state and the streams. Tests set every field; the
// command builds them from the process.
type Options struct {
	Folder    string // devzone folder: the working directory
	Package   string // package root: package.json, and the files copied from it
	AssumeYes bool   // --yes: replace the modified files without asking
	NoRebuild bool   // --no-rebuild: never offer the rebuild
	Terminal  bool   // standard input is a terminal: questions may be asked
	In        *bufio.Reader
	Out       io.Writer
	Err       io.Writer
	// RebuildCmd replaces "make -C <folder> rebuild" when set (DEVZONE_REBUILD)
	RebuildCmd string
	// PortsCmd replaces "devzone workspace ports start" when set (DEVZONE_PORTS_RESTART)
	PortsCmd string
	// Now gives the time of the backup folder name; nil means the real clock
	Now func() string
	Run Commander
}

// PackageVersion returns the version of the package at root (its package.json),
// or manifest.UnknownVersion when it cannot be read. Why: the update writes this
// version in the manifest, and the "up to date" check compares it with the folder.
func PackageVersion(root string) string {
	data, err := os.ReadFile(filepath.Join(root, "package.json"))
	if err != nil {
		return manifest.UnknownVersion
	}
	var pkg struct {
		Version string `json:"version"`
	}
	if err := json.Unmarshal(data, &pkg); err != nil || pkg.Version == "" {
		return manifest.UnknownVersion
	}
	return pkg.Version
}

// Run updates the devzone folder and returns the exit status of the command.
// Why: this is the one entry point; every refusal happens before any change, so
// a refused update leaves the folder exactly as it was.
func Run(o Options) int {
	pkgFiles, err := manifest.PackageFiles(o.Package)
	if err != nil {
		fmt.Fprintf(o.Err, "devzone: %v\n", err)
		return 1
	}
	installed := manifest.FolderVersion(o.Folder)
	pkgVersion := PackageVersion(o.Package)
	if installed == pkgVersion && !anyMissing(o.Folder, pkgFiles) {
		fmt.Fprintf(o.Out, "✔ devzone %s: already up to date.\n", installed)
		fmt.Fprintln(o.Out, "For the latest published version: npx devzone@latest update")
		return 0
	}
	fmt.Fprintf(o.Out, "devzone: folder %s, package %s\n", installed, pkgVersion)

	p := buildPlan(o, pkgFiles, sortedCopy(manifest.ManifestFiles(o.Folder)))
	if len(p.modified) > 0 {
		if code, stop := confirmModified(o, p.modified); stop {
			return code
		}
	}
	if err := backup(o, p); err != nil {
		fmt.Fprintf(o.Err, "devzone: backup: %v\n", err)
		return 1
	}
	if err := apply(o, p, pkgFiles, pkgVersion); err != nil {
		fmt.Fprintf(o.Err, "devzone: %v\n", err)
		return 1
	}
	fmt.Fprintf(o.Out, "✔ devzone %s: updated.\n", pkgVersion)
	restartPortsWatcher(o)
	return offerRebuild(o)
}

// anyMissing tells whether one of the package files is not in the folder. Why: a
// folder at the same version whose file was deleted must still be repaired.
func anyMissing(folder string, pkgFiles []string) bool {
	for _, rel := range pkgFiles {
		if !isRegular(filepath.Join(folder, filepath.FromSlash(rel))) {
			return true
		}
	}
	return false
}

// confirmModified lists the locally modified files and asks before replacing
// them. It returns the status to exit with and whether the update must stop. Why:
// a user's change is replaced only on an explicit yes (--yes or an answer).
func confirmModified(o Options, modified []string) (int, bool) {
	fmt.Fprintln(o.Out, "Locally modified files:")
	for _, rel := range modified {
		fmt.Fprintf(o.Out, "  %s\n", rel)
	}
	if o.AssumeYes {
		return 0, false
	}
	if !o.Terminal {
		fmt.Fprintln(o.Err, "✖ Locally modified files: rerun with --yes to replace them (backup in .devzone.backup/).")
		return 1, true
	}
	if !ask(o, "Replace these files (backup in .devzone.backup/)? [y/N] ") {
		fmt.Fprintln(o.Out, "Aborted: nothing was modified.")
		return 1, true
	}
	return 0, false
}

// ask writes prompt to the error stream, reads one line and tells whether it is an
// answer of yes. A read that fails (end of input) is a no, as the shell version
// of the question made it.
func ask(o Options, prompt string) bool {
	fmt.Fprint(o.Err, prompt)
	line, err := o.In.ReadString('\n')
	if err != nil {
		return false
	}
	switch strings.TrimSuffix(line, "\n") {
	case "y", "Y", "yes":
		return true
	}
	return false
}

// restartPortsWatcher starts the port watcher again when the migration of the
// legacy names stopped it. Why: the restart signal is a file the update leaves in
// the watcher folder; it is removed before the start, so a watcher the user stopped
// is never started here.
func restartPortsWatcher(o Options) {
	marker := filepath.Join(o.Folder, ".devzone.workspace-ports", "restart")
	if !isRegular(marker) {
		return
	}
	_ = os.Remove(marker)
	var code int
	if o.PortsCmd != "" {
		code = o.Run(o.Folder, o.Out, o.Err, "sh", "-c", o.PortsCmd)
	} else {
		code = o.Run(o.Folder, o.Out, o.Err, "devzone", "workspace", "ports", "start")
	}
	if code != 0 {
		fmt.Fprintln(o.Err, "devzone : port watcher not restarted: devzone workspace ports start")
	}
}

// offerRebuild asks whether the container is rebuilt now, and rebuilds it on a yes.
// Why: a Kubernetes workstation never needs a rebuild, and without a terminal the
// command is only suggested: an update never starts a rebuild on its own.
func offerRebuild(o Options) int {
	if workspaceIsKubernetes(o.Folder) {
		return 0
	}
	if o.NoRebuild {
		fmt.Fprintln(o.Out, "Rebuild not started (--no-rebuild).")
		return 0
	}
	if !o.Terminal {
		fmt.Fprintf(o.Out, "Rebuild: make -C %s rebuild (run in a terminal)\n", o.Folder)
		return 0
	}
	if !ask(o, "Rebuild the container now? [y/N] ") {
		fmt.Fprintf(o.Out, "Rebuild not started: make -C %s rebuild\n", o.Folder)
		return 0
	}
	if o.RebuildCmd != "" {
		return o.Run(o.Folder, o.Out, o.Err, "sh", "-c", o.RebuildCmd)
	}
	return o.Run(o.Folder, o.Out, o.Err, "make", "-C", o.Folder, "rebuild")
}

// workspaceIsKubernetes tells whether the last workspace= line of .devzone.modules
// is workspace=kubernetes. Why: the update never changes the workstation mode, and
// a Kubernetes workstation has no container to rebuild.
func workspaceIsKubernetes(folder string) bool {
	data, err := os.ReadFile(filepath.Join(folder, ".devzone.modules"))
	if err != nil {
		return false
	}
	last := ""
	for _, line := range strings.Split(string(data), "\n") {
		if strings.HasPrefix(line, "workspace=") {
			last = line
		}
	}
	return last == "workspace=kubernetes"
}
