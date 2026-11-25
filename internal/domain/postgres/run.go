package postgres

import (
	"context"
	"io"
)

// Run dispatches a postgres subcommand and returns its exit status. An unknown
// subcommand prints the same usage line and exits with the same code as the
// shell module.
func Run(ctx context.Context, opts Options, args []string) int {
	if len(args) == 0 {
		return usage(opts)
	}
	switch args[0] {
	case "install":
		return Install(ctx, opts, args[1:])
	case "uninstall":
		return Uninstall(ctx, opts, args[1:])
	case "status":
		return Status(ctx, opts, args[1:])
	case "create":
		return Create(ctx, opts, args[1:])
	case "list":
		return List(ctx, opts, args[1:])
	case "psql":
		return PSQL(ctx, opts, args[1:])
	case "delete":
		return Delete(ctx, opts, args[1:])
	case "relay-start":
		return RelayStart(ctx, opts, args[1:])
	case "relay-stop":
		return RelayStop(ctx, opts, args[1:])
	case "authorize":
		return Authorize(ctx, opts, args[1:])
	case "forbid":
		return Forbid(ctx, opts, args[1:])
	default:
		return usage(opts)
	}
}

// usage writes the shell usage line on standard error.
func usage(opts Options) int {
	if opts.Err != nil {
		_, _ = io.WriteString(opts.Err, "devzone postgres: create <project> [--new-password] | list | psql [<project>] | delete <project> [--yes]\n")
	}
	return 1
}
