package mysql

import (
	"bytes"
	"fmt"
	"io"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/domain/argocd"
)

// argocdState reports whether the Argo CD module holds MySQL. Exit status 2
// means that the module is on without a usable revision: that is an error and
// not a reason to install with helm, so the reason is returned to the caller.
func (e *env) argocdState() (bool, error) {
	var reason bytes.Buffer
	opts := argocd.Options{
		Runner:    e.runner(),
		Out:       io.Discard,
		Err:       &reason,
		Root:      e.root,
		StatePath: e.state.Path(),
	}
	code := argocd.Run(e.ctx, []string{"catalog-active", "mysql"}, io.Discard, &reason, opts)
	if code == 0 {
		return true, nil
	}
	if code == 2 {
		return false, fmt.Errorf("%s", reason.String())
	}
	return false, nil
}

// installArgoCD installs the Application devzone-mysql, waits for its pods and
// starts the relay, keeping the namespace and secret created apart.
func (e *env) installArgoCD(ctxName string) int {
	if err := e.mysqlSecret(); err != nil {
		e.fail("%v", err)
		return 1
	}
	claim, code := e.claimChoose(ns)
	if code != 0 {
		return code
	}
	extra := ""
	if claim != "donnees" {
		extra = "claim=" + claim
	}
	if err := e.argocdApply(ns, extra); err != nil {
		e.fail("%v", err)
		return 1
	}
	if err := e.waitRollout(ctxName, ns); err != nil {
		e.fail("%v", err)
		return 1
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

// argocdApply calls the Go Argo CD module so the Application is built exactly
// as in the pod command.
func (e *env) argocdApply(namespace, extra string) error {
	opts := argocd.Options{
		Runner:    e.runner(),
		Out:       e.opts.Out,
		Err:       e.opts.Err,
		Root:      e.root,
		StatePath: e.state.Path(),
	}
	args := []string{"catalog-apply", "mysql", namespace,
		setting("MYSQL_IMAGE", "mysql:8.4"), setting("MYSQL_PORT", "3306"),
		setting("MYSQL_MEMOIRE", "1Gi"), setting("MYSQL_TAILLE", "5Gi")}
	if extra != "" {
		args = append(args, extra)
	}
	if code := argocd.Run(e.ctx, args, e.opts.Out, e.opts.Err, opts); code != 0 {
		return fmt.Errorf("catalog-apply: exit %d", code)
	}
	return nil
}

// argocdDelete removes the Application through the Go Argo CD module; the
// namespace and the volumes stay, as in the shell module.
func (e *env) argocdDelete() error {
	opts := argocd.Options{
		Runner:    e.runner(),
		Out:       e.opts.Out,
		Err:       e.opts.Err,
		Root:      e.root,
		StatePath: e.state.Path(),
	}
	if code := argocd.Run(e.ctx, []string{"catalog-delete", "mysql"}, e.opts.Out, e.opts.Err, opts); code != 0 {
		return fmt.Errorf("catalog-delete: exit %d", code)
	}
	return nil
}
