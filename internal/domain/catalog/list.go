package catalog

import (
	"bytes"
	"encoding/json"
	"io"
	"os"
	"strings"
)

// List prints the catalog applications with their state and description.
func (e *env) List() int {
	names, err := e.apps()
	if err != nil {
		e.warn("%v", err)
		return 1
	}
	for _, app := range names {
		label := map[string]string{
			"available": "off available",
			"installed": "on installed",
			"failed":    "on failed",
			"expected":  "on expected",
		}[e.appState(app)]
		e.out("  %-12s %-14s %s", app, label, e.appRead(app, "description"))
	}
	return 0
}

// Summary prints the application lines of "devzone" and warns about unused
// MySQL volumes. A warning never changes the exit status.
func (e *env) Summary() int {
	names, err := e.apps()
	if err != nil {
		e.warn("%v", err)
		return 1
	}
	for _, app := range names {
		switch stateName := e.appState(app); stateName {
		case "available":
			e.out("  ○ application %-12s available, %s: devzone enable %s",
				app, e.appRead(app, "description"), app)
		case "installed":
			e.summaryInstalled(app)
		case "expected":
			e.out("  ⚠ application %-12s expected: devzone apply", app)
		default:
			e.out("  ✖ application %s failed: %s: devzone apply", app, e.failureFirstLine(app))
		}
	}
	e.unusedMySQLVolumes()
	return 0
}

// summaryInstalled prints an installed application with its relay address.
func (e *env) summaryInstalled(app string) {
	if e.relayStopped(app) {
		e.out("  ⚠ application %-12s installed, relay stopped: devzone repair", app)
		return
	}
	if setting("DEVZONE_WORKSPACE", "") == "kubernetes" {
		e.out("  ✔ application %-12s installed: local access: devzone workspace ports", app)
		return
	}
	e.out("  ✔ application %-12s installed: 127.0.0.1:%s", app, e.appRead(app, "port"))
}

// failureFirstLine returns the first line of the failure marker.
func (e *env) failureFirstLine(app string) string {
	data, err := os.ReadFile(e.failureFile(app))
	if err != nil {
		return ""
	}
	return strings.SplitN(string(data), "\n", 2)[0]
}

// jsonApp is one element of the applications section of "devzone status --json".
type jsonApp struct {
	Name        string  `json:"name"`
	Active      bool    `json:"active"`
	Description string  `json:"description"`
	Port        string  `json:"port"`
	State       string  `json:"state"`
	Failed      *string `json:"failed"`
	Command     *string `json:"command"`
}

// JSON prints the applications array of "devzone status --json", with the same
// fields and order as the jq expression of catalog.sh.
func (e *env) JSON() int {
	names, err := e.apps()
	if err != nil {
		e.warn("%v", err)
		return 1
	}
	apps := make([]jsonApp, 0, len(names))
	for _, app := range names {
		appState := e.appState(app)
		var failure, command *string
		cmd := "devzone apply"
		switch appState {
		case "available":
			cmd = "devzone enable " + app
		case "installed":
			cmd = "devzone disable " + app
		case "failed":
			first := e.failureFirstLine(app)
			failure = &first
		}
		command = &cmd
		apps = append(apps, jsonApp{
			Name:        app,
			Active:      e.wanted(app),
			Description: e.appRead(app, "description"),
			Port:        e.appRead(app, "port"),
			State:       appState,
			Failed:      failure,
			Command:     command,
		})
	}
	var b bytes.Buffer
	encoder := json.NewEncoder(&b)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(apps); err != nil {
		e.warn("%v", err)
		return 1
	}
	if e.opts.Out != nil {
		_, _ = io.WriteString(e.opts.Out, strings.TrimSuffix(b.String(), "\n")+"\n")
	}
	return 0
}

// unusedMySQLVolumes warns about PVCs that the MySQL StatefulSet does not use.
func (e *env) unusedMySQLVolumes() {
	ctxName := e.cluster()
	if ctxName == "" {
		return
	}
	ns, err := e.appNamespace("mysql")
	if err != nil {
		return
	}
	res, err := e.kube.AccountAdmin(e.ctx, ctxName, "get", "namespace", ns)
	if err != nil || res.Code != 0 {
		return
	}
	mountedRes, err := e.k(ns, "get", "statefulset", "mysql",
		"-o", "jsonpath={.spec.volumeClaimTemplates[0].metadata.name}")
	if err != nil || mountedRes.Code != 0 {
		return
	}
	mounted := strings.TrimSpace(string(mountedRes.Stdout))
	if mounted == "" {
		return
	}
	listRes, err := e.k(ns, "get", "pvc", "-o",
		`jsonpath={range .items[*]}{.metadata.name}{"\n"}{end}`)
	if err != nil || listRes.Code != 0 {
		return
	}
	for _, pvc := range strings.Split(string(listRes.Stdout), "\n") {
		pvc = strings.TrimSpace(pvc)
		if pvc == "" || !strings.HasSuffix(pvc, "-mysql-0") || pvc == mounted+"-mysql-0" {
			continue
		}
		e.out("  ⚠ volume %s not used : devzone mysql volume", pvc)
	}
}
