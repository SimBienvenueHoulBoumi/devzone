package mysql

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/domain/argocd"
)

var versionLine = regexp.MustCompile(`"version"\s*:\s*"([^"]*)"`)

// argocdActive reports whether the Argo CD module holds this application: the
// module is on, the chart exists, Argo CD is installed and a revision is known.
func (e *env) argocdActive() bool {
	opts := argocd.Options{
		Runner:    e.runner(),
		Out:       io.Discard,
		Err:       io.Discard,
		Root:      e.root,
		StatePath: e.state.Path(),
	}
	return argocd.Run(e.ctx, []string{"catalogue-active", "mysql"}, io.Discard, io.Discard, opts) == 0
}

// revision is the Git revision of the Applications: the explicit override, or
// the version tag of the package; a development clone has no published chart.
func (e *env) revision() string {
	if value := os.Getenv("DEVZONE_ARGOCD_REVISION"); value != "" {
		return value
	}
	data, err := os.ReadFile(filepath.Join(e.root, "package.json"))
	if err != nil {
		return ""
	}
	match := versionLine.FindSubmatch(data)
	if len(match) < 2 {
		return ""
	}
	version := string(match[1])
	if version == "" || version == "0.0.0" {
		return ""
	}
	return "v" + version
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
	args := []string{"catalogue-apply", "mysql", namespace,
		setting("MYSQL_IMAGE", "mysql:8.4"), setting("MYSQL_PORT", "3306"),
		setting("MYSQL_MEMOIRE", "1Gi"), setting("MYSQL_TAILLE", "5Gi")}
	if extra != "" {
		args = append(args, extra)
	}
	if code := argocd.Run(e.ctx, args, e.opts.Out, e.opts.Err, opts); code != 0 {
		return fmt.Errorf("catalogue-apply: exit %d", code)
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
	if code := argocd.Run(e.ctx, []string{"catalogue-delete", "mysql"}, e.opts.Out, e.opts.Err, opts); code != 0 {
		return fmt.Errorf("catalogue-delete: exit %d", code)
	}
	return nil
}
