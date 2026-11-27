package command

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/bashbridge"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/platform/update"
)

// updateCommand is "devzone update [--yes] [--no-rebuild]": it brings the devzone
// folder of the current directory to the installed package (#349). The package
// root comes from the bash entry point the launcher exports (DEVZONE_BASH_ENTRY,
// manage/devzone): its folder is two levels above it. The options are checked
// before the folder, as the shell did, so a typo is reported in any folder.
func updateCommand(ctx *cli.Context) int {
	assumeYes, noRebuild := false, false
	for _, a := range ctx.Args {
		switch a {
		case "--yes":
			assumeYes = true
		case "--no-rebuild":
			noRebuild = true
		default:
			fmt.Fprintf(ctx.Err, "✖ unknown option: %s (devzone update [--yes] [--no-rebuild])\n", a)
			return 1
		}
	}
	folder, err := os.Getwd()
	if err != nil {
		fmt.Fprintf(ctx.Err, "devzone: %v\n", err)
		return 1
	}
	if !isDirectory(filepath.Join(folder, ".devcontainer")) {
		fmt.Fprintln(ctx.Err, "✖ Run this in a devzone folder (.devcontainer not found here).")
		return 1
	}
	pkg, err := packageRoot()
	if err != nil {
		fmt.Fprintf(ctx.Err, "devzone: %v\n", err)
		return 1
	}
	stdin := ctx.Stdin
	if stdin == nil {
		stdin = os.Stdin
	}
	return update.Run(update.Options{
		Folder:     folder,
		Package:    pkg,
		AssumeYes:  assumeYes,
		NoRebuild:  noRebuild,
		Terminal:   inTerminal(stdin),
		In:         bufio.NewReader(stdin),
		Out:        ctx.Out,
		Err:        ctx.Err,
		RebuildCmd: os.Getenv("DEVZONE_REBUILD"),
		PortsCmd:   os.Getenv("DEVZONE_PORTS_RESTART"),
		Run:        runWithStreams,
	})
}

// packageRoot returns the package folder: the parent of the folder of the bash
// entry point. It fails when the launcher did not say where it is, since the
// files to copy cannot be found without it.
func packageRoot() (string, error) {
	entry := os.Getenv(bashbridge.EnvVar)
	if entry == "" {
		return "", errors.New("package folder unknown (DEVZONE_BASH_ENTRY not set): run devzone through manage/devzone")
	}
	return filepath.Dir(filepath.Dir(entry)), nil
}

// isDirectory reports whether path is a directory, following links.
func isDirectory(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.IsDir()
}

// runWithStreams runs a command in dir with the standard input of the process and
// the given output streams, and returns its exit status. Why: the rebuild and the
// port watcher print their own progress, which the user must see as it happens.
// A command that cannot start gives 127, as a shell does.
func runWithStreams(dir string, out, errOut io.Writer, name string, args ...string) int {
	cmd := exec.Command(name, args...)
	cmd.Dir = dir
	cmd.Stdin = os.Stdin
	cmd.Stdout = out
	cmd.Stderr = errOut
	err := cmd.Run()
	if err == nil {
		return 0
	}
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		return exitErr.ExitCode()
	}
	fmt.Fprintf(errOut, "devzone: cannot start %s: %v\n", name, err)
	return 127
}
