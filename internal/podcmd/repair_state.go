package podcmd

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// stateVersionsScript is the installed-tools script consulted by the shell
// status; it is the same file the JSON status already reads.
func stateVersionsScript() string {
	return filepath.Clean(filepath.Join(codeRoot(), "..", "manage", "scripts", "ci", "versions.sh"))
}

// runStateOutdatedTools prints the installed-tools listing for the shell
// summary, staying silent with code 1 when the script cannot answer.
func runStateOutdatedTools(ctx *cli.Context) int {
	versions := stateVersionsScript()
	if _, err := os.Stat(versions); err != nil {
		return 1
	}
	res, err := ctx.Runner.Run(context.Background(), "bash", []string{versions, "--installees"}, exec.Opts{})
	if err != nil || res.Code != 0 {
		return 1
	}
	_, _ = io.WriteString(ctx.Out, string(res.Stdout))
	return 0
}

// runStateMissingWorktrees prints one line per worktree registered in a local
// repository but absent from this folder, without changing any repository.
func runStateMissingWorktrees(ctx *cli.Context) int {
	for _, repo := range worktreeRepos(devzoneRoot()) {
		res, err := ctx.Runner.Run(context.Background(), "git",
			[]string{"-C", repo, "worktree", "list", "--porcelain"}, exec.Opts{})
		if err != nil || res.Code != 0 {
			continue
		}
		for _, line := range strings.Split(string(res.Stdout), "\n") {
			if !strings.HasPrefix(line, "worktree ") {
				continue
			}
			path := strings.TrimPrefix(line, "worktree ")
			if !isDirectory(path) {
				fmt.Fprintln(ctx.Out, path)
			}
		}
	}
	return 0
}

// isDirectory reports whether a registered worktree path still exists here as
// a folder, matching the shell's directory test.
func isDirectory(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.IsDir()
}
