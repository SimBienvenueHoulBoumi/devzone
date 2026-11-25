package postgres

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// Delete drops the database and the role of a project, then removes its
// credentials file. Without --yes it asks for confirmation on the terminal.
func Delete(ctx context.Context, opts Options, args []string) int {
	e := newEnv(ctx, opts)
	if len(args) == 0 {
		return e.fail("project name missing")
	}
	project := args[0]
	if !e.validateProject(project) {
		return 2
	}
	yes := false
	for _, arg := range args[1:] {
		if arg == "--yes" {
			yes = true
			continue
		}
		return e.fail("unknown argument: %s", arg)
	}
	ctxName, ok := e.moduleContext()
	if !ok {
		return 2
	}
	if !e.installed(ctxName) {
		return e.fail("module disabled: devzone enable postgres")
	}
	if !yes {
		if !e.interactive() {
			return e.fail("cannot confirm without a terminal: devzone postgres delete %s --yes", project)
		}
		if e.opts.Err != nil {
			fmt.Fprintf(e.opts.Err, "Delete database %s and all its data? [y/N] ", project)
		}
		switch e.answer() {
		case "y", "Y", "yes":
		default:
			e.line("Abandon: nothing was deleted.")
			return 0
		}
	}
	script := fmt.Sprintf("DROP DATABASE IF EXISTS %s WITH (FORCE);\nDROP ROLE IF EXISTS %s;\n", project, project)
	res, err := e.psqlAdmin(strings.NewReader(script))
	if err != nil || res.Code != 0 {
		e.show(res)
		return 1
	}
	e.show(res)
	if err := os.Remove(filepath.Join(e.secrets, project+".env")); err != nil && !os.IsNotExist(err) {
		e.fail("%v", err)
		return 1
	}
	e.line("✔ database %s deleted", project)
	e.regenerate()
	return 0
}
