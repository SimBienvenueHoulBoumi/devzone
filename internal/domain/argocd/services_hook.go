package argocd

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// servicesHook handles "services-hook <svc> <on|off>". It returns 0 when done
// through Argo CD, 3 when not concerned (helm direct should continue), 1 on failure.
func (m *module) servicesHook(args []string) int {
	if len(args) < 2 {
		return 3
	}
	svc, action := args[0], args[1]
	switch svc + ":" + action {
	case "argocd:off":
		m.loadServices()
		return m.hookRelease()
	case "postgres:on", "mysql:on":
		m.loadServices()
		return m.hookOn(svc)
	case "postgres:off", "mysql:off":
		m.loadServices()
		return m.hookOff(svc)
	default:
		return 3
	}
}

// loadServices initializes conf/gitops defaults used by services reconciliation.
func (m *module) loadServices() {
	// Ensure conf path is resolved; conf() already uses DEVZONE_ARGOCD_CONF.
	_ = m.conf()
}

// chartRequire checks charts/devzone-<svc> exists and is named devzone-<svc>.
func (m *module) chartRequire(svc string) int {
	chart := m.chartPath(svc)
	data, err := os.ReadFile(filepath.Join(chart, "Chart.yaml"))
	if err != nil || !strings.Contains(string(data), "name: devzone-"+svc+"\n") {
		fmt.Fprintf(m.errOut, "✖ %s : chart charts/devzone-%s missing or misnamed (manage/docs/reference.md#devzone-charts)\n", svc, svc)
		return 2
	}
	return 0
}

// servicesList is the default services reconciled by the container hook.
var servicesList = []string{"postgres", "mysql"}

// servicesStateOf returns on|off or empty from [services] or .devzone.modules.
func (m *module) servicesStateOf(svc string) string {
	v := m.conf().Get("services", svc)
	if v == "on" || v == "off" {
		return v
	}
	data, err := os.ReadFile(m.state)
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line == svc+"=on" || line == svc+"=off" {
			return strings.TrimPrefix(line, svc+"=")
		}
	}
	return ""
}

// servicesNote writes the [services] section with svc=state.
func (m *module) servicesNote(svc, state string) int {
	entries := m.conf().Entries()
	var pairs []string
	for _, e := range entries {
		if e.Section != "services" || e.Key == svc {
			continue
		}
		pairs = append(pairs, e.Key+"="+e.Value)
	}
	pairs = append(pairs, svc+"="+state)
	if err := m.conf().Set("services", pairs...); err != nil {
		fmt.Fprintln(m.errOut, err)
		return 1
	}
	return 0
}

// argocdRevision returns the revision of the devzone charts through the shared
// rule. An unresolved revision is an error, so no caller can fall back to a
// silent direct installation.
func (m *module) argocdRevision() (string, error) {
	return ResolveRevision(m.ctx, RevisionInputs{
		Runner:   m.runner,
		Root:     m.root,
		CodeRoot: m.codeRoot,
		ConfPath: m.confPath(),
		Repo:     os.Getenv("DEVZONE_REPO_URL"),
		Chart:    "devzone",
	})
}

// catalogArgocdActive reports whether Argo CD holds the app. A module that is
// on but has no usable revision is an error, not a reason to install directly.
func (m *module) catalogArgocdActive(app string) (bool, error) {
	data, _ := os.ReadFile(m.state)
	on := false
	for _, line := range strings.Split(string(data), "\n") {
		if strings.TrimSpace(line) == "argocd=on" {
			on = true
		}
	}
	if !on {
		return false, nil
	}
	if _, err := os.Stat(m.chartPath(app)); err != nil {
		return false, nil
	}
	if !m.isInstalled() {
		return false, nil
	}
	if _, err := m.argocdRevision(); err != nil {
		return false, err
	}
	return true, nil
}
