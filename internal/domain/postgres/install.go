package postgres

import (
	"bytes"
	"context"
	"fmt"
	"os"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/platform/helm"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/platform/relay"
)

// Install installs PostgreSQL on the chosen cluster: namespace, administrator
// secret, chart, rollout and relay. It is the Go port of "postgres install".
func Install(ctx context.Context, opts Options, args []string) int {
	e := newEnv(ctx, opts)
	ctxName, ok := e.moduleContext()
	if !ok {
		return 2
	}
	if err := e.kube.ClusterPrepare(e.ctx, ctxName, e.opts.Out, e.opts.Err); err != nil {
		return 1
	}
	if !e.kube.DevzoneContextSet(e.ctx, ctxName) {
		e.fail("cannot set the devzone context on %s", ctxName)
		return 1
	}
	e.line("▶ PostgreSQL on cluster %s (namespace %s)…", ctxName, ns)
	if !e.createNamespace(ctxName) {
		return 1
	}
	if err := e.adminSecret(); err != nil {
		e.fail("%v", err)
		return 1
	}
	size := setting("POSTGRES_TAILLE", "5Gi")
	_, code := helm.Install(e.ctx, e.runner(), e.codeRoot, "postgres", ns, []string{"size=" + size}, e.opts.Err)
	if code != 0 {
		return code
	}
	wait := setting("POSTGRES_ATTENTE", "300")
	e.line("▶ Waiting for PostgreSQL (timeout %ss)…", wait)
	res, err := e.k("rollout", "status", "statefulset/postgres", "--timeout="+wait+"s")
	if err != nil || res.Code != 0 {
		e.showErr(res)
		if e.opts.Err != nil {
			fmt.Fprintf(e.opts.Err, "devzone : postgres : not ready after %ss: kubectl --context %s -n %s describe pod postgres-0\n", wait, ctxName, ns)
		}
		return 1
	}
	relay.Stop(e.secrets, "postgres")
	port := setting("POSTGRES_PORT", "5432")
	if err := relay.Start(e.secrets, "postgres", ctxName, ns, "svc/postgres",
		[]string{port + ":5432"}, e.opts.Launcher); err != nil {
		e.fail("%v", err)
		return 1
	}
	e.line("✔ PostgreSQL ready: 127.0.0.1:%s in the container", port)
	e.line("  Database for a project: devzone postgres create <project>")
	e.regenerate()
	return 0
}

// createNamespace creates, labels and allows the namespace as administrator.
func (e *env) createNamespace(ctxName string) bool {
	created, err := e.kube.AccountAdmin(e.ctx, ctxName, "create", "namespace", ns, "--dry-run=client", "-o", "yaml")
	if err != nil || created.Code != 0 {
		e.showErr(created)
		return false
	}
	applied, err := e.kube.AccountAdminInput(e.ctx, ctxName, bytes.NewReader(created.Stdout), "apply", "-f", "-")
	if err != nil || applied.Code != 0 {
		e.showErr(applied)
		return false
	}
	labeled, err := e.kube.AccountAdmin(e.ctx, ctxName, "label", "namespace", ns,
		"app.kubernetes.io/managed-by=devzone", "--overwrite")
	if err != nil || labeled.Code != 0 {
		e.showErr(labeled)
		return false
	}
	if err := e.kube.AccountAllow(e.ctx, ctxName, ns, e.opts.Err); err != nil {
		e.fail("%v", err)
		return false
	}
	return true
}

// Uninstall stops the relay, removes the namespace as administrator, releases
// the dedicated cluster and deletes the local secrets; data on a host cluster
// is deleted with the namespace.
func Uninstall(ctx context.Context, opts Options, args []string) int {
	e := newEnv(ctx, opts)
	relay.Stop(e.secrets, "postgres")
	ctxName := e.cluster()
	if ctxName != "" && !e.kube.DevzoneContextSet(e.ctx, ctxName) {
		if e.opts.Err != nil {
			fmt.Fprintf(e.opts.Err, "devzone : postgres : devzone context not set on %s; local cleanup only\n", ctxName)
		}
	}
	if ctxName != "" && e.installed(ctxName) {
		e.line("▶ Deleting PostgreSQL and all its databases on %s…", ctxName)
		_ = e.kube.AccountRemove(e.ctx, ctxName, ns)
		res, err := e.kube.AccountAdmin(e.ctx, ctxName, "delete", "namespace", ns, "--wait=true")
		if err != nil || res.Code != 0 {
			e.showErr(res)
			return 1
		}
		if err := e.kube.ClusterRelease(e.ctx, ctxName, e.opts.Out, e.opts.Err); err != nil {
			e.fail("%v", err)
			return 1
		}
	}
	if err := os.RemoveAll(e.secrets); err != nil {
		e.fail("%v", err)
		return 1
	}
	e.line("✔ PostgreSQL uninstalled.")
	e.regenerate()
	return 0
}

// relayStart starts the port-forward with the same target and port as the
// shell module.
func relayStart(e *env, ctxName, port string) error {
	return relay.Start(e.secrets, "postgres", ctxName, ns, "svc/postgres",
		[]string{port + ":5432"}, e.opts.Launcher)
}

// stopRelay stops the detached port-forward and removes its PID file.
func (e *env) stopRelay() { relay.Stop(e.secrets, "postgres") }
