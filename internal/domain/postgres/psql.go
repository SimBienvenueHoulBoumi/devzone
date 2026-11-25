package postgres

import (
	"context"
)

// PSQL opens an interactive psql console in the pod, as superuser or as the
// owner of a project. The terminal is attached when standard input is a TTY.
func PSQL(ctx context.Context, opts Options, args []string) int {
	e := newEnv(ctx, opts)
	ctxName, ok := e.moduleContext()
	if !ok {
		return 2
	}
	if !e.installed(ctxName) {
		return e.fail("module disabled: devzone enable postgres")
	}
	project := ""
	if len(args) > 0 {
		project = args[0]
		if !e.validateProject(project) {
			return 2
		}
	}
	consoleArgs := []string{"exec", "-i"}
	if e.isTTY() {
		consoleArgs = append(consoleArgs, "-t")
	}
	consoleArgs = append(consoleArgs, "postgres-0", "-c", "postgres", "--", "psql", "-U")
	if project != "" {
		consoleArgs = append(consoleArgs, project, "-d", project)
	} else {
		consoleArgs = append(consoleArgs, "postgres")
	}
	res, err := e.kInput(e.opts.Stdin, consoleArgs...)
	if err != nil {
		e.fail("%v", err)
		return 1
	}
	e.show(res)
	return res.Code
}
