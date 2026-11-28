package podcmd

import (
	"context"
	"fmt"
	"strings"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// safeDirectory is the worktree root git must trust inside the workspace pod.
const safeDirectory = "/workspaces/projets/*"

// applyInitModules applies the enabled modules in this process, exactly as
// "devzone apply" does. It is a variable so tests can force a module failure
// without changing a real instance state.
var applyInitModules = func(ctx *cli.Context) int { return newModules(ctx).apply() }

// runInit performs the four startup steps in order and reports whether every
// step succeeded; a failing step is logged but never stops the next one.
func runInit(ctx *cli.Context) int {
	setCoreLimit()
	failed := false
	if !initSafeDirectory(ctx) {
		failed = true
	}
	if !initRepowarden(ctx) {
		failed = true
	}
	if !initModules(ctx) {
		failed = true
	}
	if !initPrompt(ctx) {
		failed = true
	}
	logInit(ctx, "done")
	if failed {
		return 1
	}
	return 0
}

// logInit writes one startup journal line with the prefix used by the pod.
func logInit(ctx *cli.Context, message string) {
	_, _ = fmt.Fprintf(ctx.Out, "devzone init: %s\n", message)
}

// initSafeDirectory adds the pod worktree root to git's global safe.directory
// list when it is absent, so git commands in worktrees keep working.
func initSafeDirectory(ctx *cli.Context) bool {
	current, err := ctx.Runner.Run(context.Background(), "git",
		[]string{"config", "--global", "--get-all", "safe.directory"}, exec.Opts{})
	if err == nil && current.Code == 0 && hasExactLine(string(current.Stdout), safeDirectory) {
		logInit(ctx, "safe.directory "+safeDirectory+" already set")
		return true
	}
	added, err := ctx.Runner.Run(context.Background(), "git",
		[]string{"config", "--global", "--add", "safe.directory", safeDirectory}, exec.Opts{})
	if err != nil || added.Code != 0 {
		logInit(ctx, "safe.directory: failed")
		return false
	}
	logInit(ctx, "safe.directory "+safeDirectory+" added")
	return true
}

// hasExactLine reports whether text holds wanted as a whole line, as grep -x did.
func hasExactLine(text, wanted string) bool {
	for _, line := range strings.Split(strings.TrimRight(text, "\n"), "\n") {
		if strings.TrimSuffix(line, "\r") == wanted {
			return true
		}
	}
	return false
}

// initModules applies the enabled modules in process and logs the result; the
// remaining startup steps still run when the application is incomplete.
func initModules(ctx *cli.Context) bool {
	if applyInitModules(ctx) == 0 {
		logInit(ctx, "modules applied")
		return true
	}
	logInit(ctx, "modules incomplete")
	return false
}
