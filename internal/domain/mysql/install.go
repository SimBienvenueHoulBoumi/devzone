package mysql

import (
	"context"
	"fmt"
	"time"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/platform/helm"
)

// Install installs MySQL on the chosen cluster, through an Argo CD Application
// when the argocd module holds it, otherwise with helm direct.
func Install(ctx context.Context, opts Options, args []string) int {
	e := newEnv(ctx, opts)
	ctxName, ok := e.moduleContext()
	if !ok {
		return 2
	}
	if !e.kube.DevzoneContextSet(e.ctx, ctxName) {
		if e.opts.Err != nil {
			fmt.Fprintf(e.opts.Err, "devzone : catalog mysql : cannot set the devzone context on %s\n", ctxName)
		}
		return 1
	}
	e.line("▶ MySQL on cluster %s (namespace %s)…", ctxName, ns)
	if e.argocdActive() {
		return e.installArgoCD(ctxName)
	}
	return e.installDirect(ctxName)
}

// installDirect creates the namespace, the secret and the StatefulSet with
// helm, adopting an existing installation instead of recreating its volume.
func (e *env) installDirect(ctxName string) int {
	if err := e.kube.NamespaceCreate(e.ctx, ctxName, ns, e.opts.Err); err != nil {
		e.fail("%v", err)
		return 1
	}
	if err := e.kube.NamespaceIsolate(e.ctx, ns, nil); err != nil {
		e.fail("%v", err)
		return 1
	}
	if res, err := e.k("get", "statefulset", "mysql"); err == nil && res.Code == 0 {
		e.line("devzone : catalog mysql : existing installation in %s, adopted (volume and root.env kept)", ns)
	} else {
		if err := e.mysqlSecret(); err != nil {
			e.fail("%v", err)
			return 1
		}
		claim, code := e.claimChoose(ns)
		if code != 0 {
			return code
		}
		if code := e.applyChart(ns, claim); code != 0 {
			return code
		}
		if err := e.waitRollout(ctxName, ns); err != nil {
			e.fail("%v", err)
			return 1
		}
	}
	if err := e.mysqlSecret(); err != nil {
		e.fail("%v", err)
		return 1
	}
	e.relayStart(ctxName, ns)
	e.line("✔ MySQL ready: 127.0.0.1:%s in the container", setting("MYSQL_PORT", "3306"))
	e.regenerate()
	return 0
}

// installClaim reinstalls the StatefulSet on the requested PVC, keeping data.
func (e *env) installClaim(ctxName, namespace, claim string) int {
	if !e.kube.DevzoneContextSet(e.ctx, ctxName) {
		if e.opts.Err != nil {
			fmt.Fprintf(e.opts.Err, "devzone : catalog mysql : cannot set the devzone context on %s\n", ctxName)
		}
		return 1
	}
	e.line("▶ MySQL on cluster %s (namespace %s, volume %s-mysql-0)…", ctxName, namespace, claim)
	if err := e.kube.NamespaceCreate(e.ctx, ctxName, namespace, e.opts.Err); err != nil {
		e.fail("%v", err)
		return 1
	}
	if err := e.kube.NamespaceIsolate(e.ctx, namespace, nil); err != nil {
		e.fail("%v", err)
		return 1
	}
	if err := e.mysqlSecret(); err != nil {
		e.fail("%v", err)
		return 1
	}
	res, err := e.k("delete", "statefulset", "mysql", "--ignore-not-found")
	if err != nil {
		e.fail("%v", err)
		return 1
	}
	_ = res
	if code := e.applyChart(namespace, claim); code != 0 {
		return code
	}
	if err := e.waitRollout(ctxName, namespace); err != nil {
		e.fail("%v", err)
		return 1
	}
	if err := e.mysqlSecret(); err != nil {
		e.fail("%v", err)
		return 1
	}
	e.relayStart(ctxName, namespace)
	e.line("✔ MySQL ready: 127.0.0.1:%s in the container", setting("MYSQL_PORT", "3306"))
	e.regenerate()
	return 0
}

// applyChart installs charts/devzone-mysql with the values of app.conf.
func (e *env) applyChart(namespace, claim string) int {
	sets := []string{
		"image=" + setting("MYSQL_IMAGE", "mysql:8.4"),
		"port=" + setting("MYSQL_PORT", "3306"),
		"memory=" + setting("MYSQL_MEMOIRE", "1Gi"),
		"size=" + setting("MYSQL_TAILLE", "5Gi"),
		"claim=" + claim,
	}
	_, code := helm.Install(e.ctx, e.runner(), e.codeRoot, "mysql", namespace, sets, e.opts.Err)
	return code
}

// waitRollout polls the StatefulSet created by helm or Argo CD until it is ready.
func (e *env) waitRollout(ctxName, namespace string) error {
	wait := setting("MYSQL_ATTENTE", "300")
	seconds := 0
	for seconds < atoi(wait) {
		res, err := e.k("rollout", "status", "statefulset/mysql", "--timeout=10s")
		if err == nil && res.Code == 0 {
			return nil
		}
		e.sleep(5 * time.Second)
		seconds += 5
	}
	if e.opts.Err != nil {
		fmt.Fprintf(e.opts.Err, "devzone : catalog mysql : not ready after %ss: kubectl --context %s -n %s describe pod mysql-0\n", wait, ctxName, namespace)
	}
	return fmt.Errorf("mysql not ready")
}

// atoi parses a decimal timeout, defaulting to zero when it is not a number.
func atoi(value string) int {
	n := 0
	for _, r := range value {
		if r < '0' || r > '9' {
			return 0
		}
		n = n*10 + int(r-'0')
	}
	return n
}
