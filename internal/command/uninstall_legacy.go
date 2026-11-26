package command

import (
	"os"
	"path/filepath"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/bashbridge"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
)

// legacyUninstaller returns the uninstaller kept in a devzone created before
// the Go port, if any. Those folders own their removal procedure: the Go
// command must run it instead of inventing a new plan for them.
func legacyUninstaller(root string) string {
	for _, name := range []string{"uninstall.sh", "scripts/uninstall.sh", "core/scripts/uninstall.sh"} {
		path := filepath.Join(root, filepath.FromSlash(name))
		if info, err := os.Stat(path); err == nil && !info.IsDir() {
			return path
		}
	}
	return ""
}

// runLegacyUninstaller runs the script of an older devzone with the command
// name the shell launcher used, and restores the variable afterwards so the
// next command of the process keeps its own name.
func runLegacyUninstaller(ctx *cli.Context, script string) int {
	previous, hadPrevious := os.LookupEnv("DEVZONE_COMMAND")
	_ = os.Setenv("DEVZONE_COMMAND", "devzone uninstall")
	defer func() {
		if hadPrevious {
			_ = os.Setenv("DEVZONE_COMMAND", previous)
		} else {
			_ = os.Unsetenv("DEVZONE_COMMAND")
		}
	}()
	return bashbridge.Run(script, ctx.Args, ctx.Stdin, ctx.Out, ctx.Err)
}
