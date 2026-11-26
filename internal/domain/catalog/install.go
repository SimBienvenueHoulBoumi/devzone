package catalog

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/platform/helm"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/platform/kube"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/platform/relay"
)

// install installs one application: devzone context, namespace, secret, chart
// or Argo CD Application, wait for readiness and start its relay.
func (e *env) install(app string) int {
	ns, err := e.appNamespace(app)
	if err != nil {
		return e.refuse("%s", err.Error())
	}
	port := e.appRead(app, "port")
	image := e.appRead(app, "image")
	ctxName := e.cluster()
	if ctxName == "" {
		return e.refuse("no cluster chosen: devzone enable %s", app)
	}
	if !e.kube.DevzoneContextSet(e.ctx, ctxName) {
		e.warn("devzone : catalog : cannot set the devzone context on %s", ctxName)
		return 1
	}
	e.out("▶ Application %s on cluster %s (namespace %s)…", app, ctxName, ns)
	claim := "donnees"
	extra := ""
	if app == "mysql" {
		claim, err = e.mysqlClaim(ns)
		if err != nil {
			return e.refuse("%s", err.Error())
		}
		if claim != "donnees" {
			extra = "claim=" + claim
		}
	}
	argo, err := e.argocdState(app)
	if err != nil {
		e.warn("devzone : catalog : %v", err)
		return 1
	}
	if err := e.kube.NamespaceCreate(e.ctx, ctxName, ns, e.opts.Err); err != nil {
		e.warn("devzone : catalog : %v", err)
		return 1
	}
	if err := e.kube.NamespaceIsolate(e.ctx, ns, e.opts.Err); err != nil {
		e.warn("devzone : catalog : %v", err)
		return 1
	}
	if err := e.appSecret(app, ns); err != nil {
		e.warn("devzone : catalog : %v", err)
		return 1
	}
	if argo {
		e.out("▶ Application %s through Argo CD (chart charts/devzone-%s)…", app, app)
		args := []string{"argocd", "catalog-apply", app, ns, image, port,
			e.appRead(app, "memoire"), e.appRead(app, "taille")}
		if extra != "" {
			args = append(args, extra)
		}
		res, err := e.exec(e.script, args)
		if err != nil || res.Code != 0 {
			return 1
		}
	} else {
		sets := []string{"image=" + image, "port=" + port,
			"memory=" + e.appRead(app, "memoire"), "size=" + e.appRead(app, "taille"),
			"claim=" + claim}
		_, code := helm.Install(e.ctx, e.runner(), e.codeRoot, app, ns, sets, e.opts.Err)
		if code != 0 {
			return code
		}
	}
	if err := e.appWait(app, ns, argo); err != nil {
		e.warn("devzone : catalog : %s not ready after %ss", app, setting("DEVZONE_CATALOG_WAIT", "300"))
		return 1
	}
	if err := e.startRelay(app, ctxName, ns); err != nil {
		e.warn("devzone : catalog : %v", err)
		return 1
	}
	e.out("✔ %s ready: 127.0.0.1:%s in the container", app, port)
	e.regenerate()
	return 0
}

// appWait waits for the StatefulSet: one rollout command on the direct path,
// polled when Argo CD applies the chart in the background.
func (e *env) appWait(app, ns string, argo bool) error {
	wait := setting("DEVZONE_CATALOG_WAIT", "300")
	attempts := 1
	if argo {
		attempts = atoi(wait)/5 + 1
	}
	for i := 0; i < attempts; i++ {
		res, err := e.k(ns, "rollout", "status", "statefulset/"+app, "--timeout="+wait+"s")
		if argo {
			res, err = e.k(ns, "rollout", "status", "statefulset/"+app, "--timeout=10s")
		}
		if err == nil && res.Code == 0 {
			return nil
		}
		if i+1 < attempts {
			e.sleep(5 * time.Second)
		}
	}
	return errors.New("not ready")
}

// atoi parses a positive decimal timeout, defaulting to zero.
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

// mysqlClaim asks the MySQL module which PVC to reuse, refusing an ambiguous
// choice with its list and command, as the shell call did.
func (e *env) mysqlClaim(ns string) (string, error) {
	res, err := e.exec(e.script, []string{"mysql", "claim", ns})
	if err != nil {
		return "", err
	}
	if res.Code != 0 {
		return "", errors.New(strings.TrimSpace(string(res.Stdout) + string(res.Stderr)))
	}
	return strings.TrimSpace(string(res.Stdout)), nil
}

// argocdState reports whether Argo CD holds the application. Exit status 2
// means that the module is on but the revision cannot be resolved: installing
// directly would be a silent fallback, so it is reported as an error.
func (e *env) argocdState(app string) (bool, error) {
	res, err := e.exec(e.script, []string{"argocd", "catalog-active", app})
	if err != nil {
		return false, err
	}
	if res.Code == 0 {
		return true, nil
	}
	if res.Code == 2 {
		return false, errors.New(strings.TrimSpace(string(res.Stdout) + string(res.Stderr)))
	}
	return false, nil
}

// startRelay keeps the port-forward of an application alive on 127.0.0.1.
func (e *env) startRelay(app, ctxName, ns string) error {
	port := e.appRead(app, "port")
	return relay.Start(e.relayDir(app), app, ctxName, ns, "svc/"+app,
		[]string{port + ":" + port}, e.opts.Launcher)
}

// regenerate rebuilds the grouped credentials view through the devzone launcher,
// replacing the old password.sh call; a failure never blocks the operation.
func (e *env) regenerate() {
	if e.codeRoot == "" {
		return
	}
	res, err := e.exec(e.script, []string{"passwords", "regenerate"})
	if err != nil || res.Code != 0 {
		e.warn("devzone : catalog : grouped credentials not updated (devzone passwords)")
	}
}

// appSecret generates the admin password once and mirrors it in the workspace,
// keeping a password already present in the cluster or in root.env.
func (e *env) appSecret(app, ns string) error {
	dir := filepath.Join(e.root, "workspace", "."+app)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	file := filepath.Join(dir, "admin-password")
	if res, err := e.k(ns, "get", "secret", app+"-admin"); err == nil && res.Code == 0 {
		data, err := e.k(ns, "get", "secret", app+"-admin", "-o", "jsonpath={.data.password}")
		if err != nil {
			return err
		}
		return writePassword(file, strings.TrimSpace(string(data.Stdout)))
	}
	password := envValue(filepath.Join(dir, "root.env"), strings.ToUpper(app)+"_PASSWORD")
	if password == "" {
		password = envValue(filepath.Join(dir, "root.env"), "MYSQL_PASSWORD")
	}
	if password == "" {
		if data, err := os.ReadFile(file); err == nil {
			password = strings.TrimSpace(string(data))
		}
	}
	if password == "" {
		res, err := e.exec("openssl", []string{"rand", "-hex", "24"})
		if err != nil {
			return err
		}
		if res.Code != 0 {
			return errors.New("openssl rand failed")
		}
		password = strings.TrimSpace(string(res.Stdout))
	}
	if err := writePassword(file, password); err != nil {
		return err
	}
	res, err := e.k(ns, "create", "secret", "generic", app+"-admin", "--from-file=password="+file)
	if err != nil {
		return err
	}
	if res.Code != 0 {
		return &kube.ExitError{Code: res.Code, Stderr: string(res.Stderr)}
	}
	return nil
}

// writePassword writes a password file with mode 600.
func writePassword(path, password string) error {
	if err := os.WriteFile(path, []byte(password), 0o600); err != nil {
		return err
	}
	return os.Chmod(path, 0o600)
}

// envValue returns the last value of key in an env file.
func envValue(path, key string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	prefix := key + "="
	found := ""
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSuffix(line, "\r")
		if strings.HasPrefix(line, prefix) {
			found = strings.TrimPrefix(line, prefix)
		}
	}
	return found
}
