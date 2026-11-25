package mysql

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

var versionLine = regexp.MustCompile(`"version"\s*:\s*"([^"]*)"`)

// argocdActive reports whether the Argo CD module holds this application: the
// module is on, the chart exists, Argo CD is installed and a revision is known.
func (e *env) argocdActive() bool {
	if strings.TrimSpace(e.state.Get("argocd")) != "on" {
		return false
	}
	if e.codeRoot == "" {
		return false
	}
	if _, err := os.Stat(filepath.Join(e.codeRoot, "charts", "devzone-mysql")); err != nil {
		return false
	}
	if !e.namespaceExists(e.activeAdminContext(), "devzone-argocd") {
		return false
	}
	return e.revision() != ""
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

// shellEnv is the environment of the Argo CD shell library called below.
func (e *env) shellEnv() []string {
	return append(os.Environ(),
		"RACINE="+e.codeRoot,
		"DEVZONE_ROOT="+e.root,
		"DEVZONE_STATE="+e.state.Path(),
		"ETAT="+e.state.Path(),
	)
}

// argocdApply calls the shared catalogue_argocd_apply function so the
// Application is built exactly as in the Argo CD module.
func (e *env) argocdApply(namespace, extra string) error {
	body := `. "$1"; catalogue_argocd_apply mysql "$2" "$3" "$4" "$5" "$6" "$7"`
	args := []string{"-c", body, "_", filepath.Join(e.codeRoot, "argocd", "catalog-argocd.sh"),
		"mysql", namespace, setting("MYSQL_IMAGE", "mysql:8.4"), setting("MYSQL_PORT", "3306"),
		setting("MYSQL_MEMOIRE", "1Gi"), setting("MYSQL_TAILLE", "5Gi"), extra}
	res, err := e.execEnv("bash", args, nil, e.shellEnv())
	if err != nil {
		return err
	}
	if res.Code != 0 {
		return fmt.Errorf("catalogue_argocd_apply: exit %d", res.Code)
	}
	e.show(res)
	return nil
}

// argocdDelete removes the Application through the shared Argo CD library;
// the namespace and the volumes stay, as in the shell module.
func (e *env) argocdDelete() error {
	body := `. "$1"; catalogue_argocd_delete mysql`
	args := []string{"-c", body, "_", filepath.Join(e.codeRoot, "argocd", "catalog-argocd.sh")}
	res, err := e.execEnv("bash", args, nil, e.shellEnv())
	if err != nil {
		return err
	}
	if res.Code != 0 {
		return fmt.Errorf("catalogue_argocd_delete: exit %d", res.Code)
	}
	e.show(res)
	return nil
}
