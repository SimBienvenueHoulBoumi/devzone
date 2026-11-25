package mysql

import (
	"context"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/platform/relay"
)

// RelayStart restarts the MySQL port-forward when the module is installed.
func RelayStart(ctx context.Context, opts Options, args []string) int {
	e := newEnv(ctx, opts)
	ctxName := e.cluster()
	if ctxName != "" && e.installed(e.activeAdminContext()) {
		e.relayStart(ctxName, ns)
	}
	return 0
}

// RelayStop stops the detached port-forward and removes its PID file.
func RelayStop(ctx context.Context, opts Options, args []string) int {
	relay.Stop(newEnv(ctx, opts).secrets, "mysql")
	return 0
}
