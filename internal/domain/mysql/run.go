package mysql

import (
	"context"
	"io"
)

// Run dispatches a mysql subcommand and returns its exit status. An unknown
// subcommand prints the same usage line and exits with the shell status.
func Run(ctx context.Context, opts Options, args []string) int {
	if len(args) == 0 {
		return usage(opts)
	}
	switch args[0] {
	case "install":
		return Install(ctx, opts, args[1:])
	case "delete-data":
		return DeleteData(ctx, opts, args[1:])
	case "status":
		return Status(ctx, opts, args[1:])
	case "create":
		return Create(ctx, opts, args[1:])
	case "list":
		return List(ctx, opts, args[1:])
	case "delete":
		return Delete(ctx, opts, args[1:])
	case "volume":
		return Volume(ctx, opts, args[1:])
	case "claim":
		return Claim(ctx, opts, args[1:])
	case "relay-start":
		return RelayStart(ctx, opts, args[1:])
	case "relay-stop":
		return RelayStop(ctx, opts, args[1:])
	default:
		return usage(opts)
	}
}

// usage writes the shell usage line on standard error.
func usage(opts Options) int {
	if opts.Err != nil {
		_, _ = io.WriteString(opts.Err, "devzone : catalog mysql : create <project> [--new-password] | list | delete <project> [--yes] | volume [<name>] [--delete <name>] [--yes] | delete-data [--yes]\n")
	}
	return 1
}
