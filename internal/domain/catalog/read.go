package catalog

import (
	"bufio"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/platform/relay"
)

// apps returns the catalog application names, sorted as LC_ALL=C sort did.
func (e *env) apps() ([]string, error) {
	entries, err := os.ReadDir(e.catalog)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	var names []string
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		if info, err := os.Stat(filepath.Join(e.catalog, entry.Name(), "app.conf")); err == nil && !info.IsDir() {
			names = append(names, entry.Name())
		}
	}
	sort.Strings(names)
	return names, nil
}

// appRead returns the last value of key in app.conf, or an empty string.
func (e *env) appRead(app, key string) string {
	data, err := os.ReadFile(filepath.Join(e.catalog, app, "app.conf"))
	if err != nil {
		return ""
	}
	prefix := key + "="
	found := ""
	scanner := bufio.NewScanner(strings.NewReader(string(data)))
	for scanner.Scan() {
		line := strings.TrimSuffix(scanner.Text(), "\r")
		if strings.HasPrefix(line, prefix) {
			found = strings.TrimPrefix(line, prefix)
		}
	}
	return found
}

// appNamespace returns the required namespace of an application.
func (e *env) appNamespace(app string) (string, error) {
	ns := strings.TrimSpace(e.appRead(app, "namespace"))
	if ns == "" {
		return "", &refusal{Message: "missing namespace in app.conf of " + app}
	}
	return ns, nil
}

// refusal is a catalog refusal with the shell's exit status 2.
type refusal struct{ Message string }

// Error implements the error interface.
func (r *refusal) Error() string { return r.Message }

// failureFile is the marker of the last failure of an application.
func (e *env) failureFile(app string) string { return e.statePath + "-failed-" + app }

// wanted reports on only when the last <app>= line of the state says on.
func (e *env) wanted(app string) bool {
	return strings.TrimSpace(e.stateValue(app)) == "on"
}

// stateValue returns the last value of key in the state file.
func (e *env) stateValue(key string) string {
	data, err := os.ReadFile(e.statePath)
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

// present reports whether the application is installed. In the Kubernetes
// workspace pod its service resolves in the cluster DNS, without RBAC;
// elsewhere the labelled namespace and StatefulSet are read by the administrator.
func (e *env) present(app string) bool {
	ns, err := e.appNamespace(app)
	if err != nil {
		return false
	}
	if setting("DEVZONE_WORKSPACE", "") == "kubernetes" {
		res, runErr := e.exec("getent", []string{"hosts", e.appRead(app, "name") + "." + ns + ".svc"})
		return runErr == nil && res.Code == 0
	}
	ctxName := e.cluster()
	if ctxName == "" {
		return false
	}
	nsRes, err := e.kube.AccountAdmin(e.ctx, ctxName, "get", "namespace", ns)
	if err != nil || nsRes.Code != 0 {
		return false
	}
	res, err := e.k(ns, "get", "statefulset", app)
	return err == nil && res.Code == 0
}

// appReady reports whether the StatefulSet has one ready replica.
func (e *env) appReady(app string) bool {
	ns, err := e.appNamespace(app)
	if err != nil {
		return false
	}
	res, err := e.k(ns, "get", "statefulset", app, "-o", "jsonpath={.status.readyReplicas}")
	return err == nil && res.Code == 0 && strings.TrimSpace(string(res.Stdout)) == "1"
}

// appState returns the displayed state of an application: available, expected,
// installed or failed.
func (e *env) appState(app string) string {
	if !e.wanted(app) {
		return "available"
	}
	if _, err := os.Stat(e.failureFile(app)); err == nil {
		return "failed"
	}
	if e.present(app) {
		return "installed"
	}
	return "expected"
}

// relayDir is the workspace folder holding the pid and log of an app relay.
func (e *env) relayDir(app string) string { return filepath.Join(e.root, "workspace", "."+app) }

// relayStopped reports whether the relay of an installed application is down.
func (e *env) relayStopped(app string) bool {
	if setting("DEVZONE_WORKSPACE", "") == "kubernetes" {
		return false
	}
	script := filepath.Join(e.codeRoot, "catalog", app, app+".sh")
	if _, err := os.Stat(script); err == nil {
		res, runErr := e.exec("bash", []string{script, "status"})
		if runErr == nil && res.Code == 0 && strings.Contains(string(res.Stdout), "relay stopped") {
			return true
		}
	}
	return !relay.Active(e.relayDir(app), app)
}

// appFailure keeps the last line of a message in the failure marker and writes
// the whole message on the error output, as app_failure did.
func (e *env) appFailure(app, message string) {
	lines := strings.Split(strings.TrimSuffix(message, "\n"), "\n")
	last := ""
	if len(lines) > 0 {
		last = lines[len(lines)-1]
	}
	_ = os.WriteFile(e.failureFile(app), []byte(last+"\n"), 0o644)
	e.warn("%s", message)
}
