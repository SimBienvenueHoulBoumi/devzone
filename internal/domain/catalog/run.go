package catalog

import (
	"context"
	"io"
)

const usageLine = "devzone : catalog : sync | apply | list | resume | json | remove <app>"

const helpText = `Application catalog (#414): one preconfigured application per folder
.devcontainer/catalog/<app>/ (app.conf; the chart charts/devzone-<app>, #559),
installed in the devzone services cluster under the namespace of its app.conf;
the wanted state is the line <app>=on|off of .devzone.modules.
  catalog.sh sync | apply | list | resume | json | remove <app>
`

// Run dispatches a "devzone catalog" subcommand and returns its exit status.
func Run(ctx context.Context, opts Options, args []string) int {
	e := newEnv(ctx, opts)
	if len(args) == 0 {
		return e.List()
	}
	switch args[0] {
	case "-h", "--help":
		if e.opts.Out != nil {
			_, _ = io.WriteString(e.opts.Out, helpText)
		}
		return 0
	case "sync":
		return e.sync()
	case "apply":
		return e.apply()
	case "list":
		return e.List()
	case "resume":
		return e.Summary()
	case "json":
		return e.JSON()
	case "remove":
		if len(args) != 2 {
			e.warn("%s", usageLine)
			return 1
		}
		return e.remove(args[1])
	default:
		e.warn("%s", usageLine)
		return 1
	}
}
