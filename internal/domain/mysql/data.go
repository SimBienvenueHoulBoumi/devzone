package mysql

import (
	"context"
	"fmt"
	"os"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/platform/relay"
)

// DeleteData deletes the namespace and its volumes, keeping workspace/.mysql.
// It needs --yes or a terminal confirmation.
func DeleteData(ctx context.Context, opts Options, args []string) int {
	e := newEnv(ctx, opts)
	yes := false
	for _, arg := range args {
		if arg == "--yes" {
			yes = true
			continue
		}
		return e.fail("unknown argument: %s", arg)
	}
	if !yes {
		if !e.interactive() {
			return e.fail("confirmation needs a terminal: devzone mysql delete-data --yes")
		}
		if e.opts.Err != nil {
			fmt.Fprintf(e.opts.Err, "Delete namespace %s and all its volumes? [y/N] ", ns)
		}
		switch e.answer() {
		case "y", "Y", "yes":
		default:
			e.line("Aborted: nothing was deleted.")
			return 0
		}
	}
	ctxName := e.cluster()
	if ctxName == "" {
		return e.fail("no cluster chosen: devzone enable mysql")
	}
	if !e.installed(ctxName) {
		return e.fail("module disabled: devzone enable mysql")
	}
	e.line("▶ Deleting MySQL and its volumes on %s…", ctxName)
	_ = e.argocdDelete()
	_ = e.kube.AccountRemove(e.ctx, ctxName, ns)
	res, err := e.kube.AccountAdmin(e.ctx, ctxName, "delete", "namespace", ns, "--wait=true")
	if err != nil || res.Code != 0 {
		e.showErr(res)
		return 1
	}
	relay.Stop(e.secrets, "mysql")
	if err := os.Remove(e.state.Path() + "-failed-mysql"); err != nil && !os.IsNotExist(err) {
		e.fail("%v", err)
		return 1
	}
	e.line("✔ namespace %s and volume deleted; workspace/.mysql/root.env kept", ns)
	e.regenerate()
	return 0
}
