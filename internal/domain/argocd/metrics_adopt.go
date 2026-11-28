package argocd

import (
	"fmt"
	"strings"

	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// metricsMark is the label the legacy installer puts on the deployment it
// installed by the shell installer that was removed, so devzone only removes its own copy.
const metricsMark = "installe"

// metricsAppName is the Application devzone creates for metrics-server.
const metricsAppName = "devzone-metrics-server"

// metricsApplicationExists reports whether the Application devzone-metrics-server
// exists. NotFound and an absent Application CRD both mean no Application; any
// other read error is returned so that nothing is deleted or applied.
func (m *module) metricsApplicationExists() (bool, error) {
	res, err := m.kubectl("-n", gitopsNS, "get", "application.argoproj.io", metricsAppName)
	if err != nil {
		return false, fmt.Errorf("metrics-server : cannot read Application %s: %v", metricsAppName, err)
	}
	if res.Code == 0 {
		return true, nil
	}
	stderr := string(res.Stderr)
	if strings.Contains(stderr, "NotFound") || strings.Contains(stderr, "doesn't have a resource type") {
		return false, nil
	}
	return false, fmt.Errorf("metrics-server : cannot read Application %s: %s", metricsAppName, strings.TrimSpace(stderr))
}

// metricsOwner reports who installed the metrics-server deployment of kube-system:
// "" when absent, "devzone" when the legacy installer marked it, "other" otherwise.
func (m *module) metricsOwner() (string, error) {
	res, err := m.runner.Run(m.ctx, "kubectl",
		m.kubectlArgs("-n", metricsNS, "get", "deployment", "metrics-server",
			"-o", "jsonpath={.metadata.labels.devzone}"), fexec.Opts{})
	if err != nil {
		return "", err
	}
	if res.Code != 0 {
		if strings.Contains(string(res.Stderr), "NotFound") {
			return "", nil
		}
		return "", fmt.Errorf("metrics-server : cannot read kube-system: %s", strings.TrimSpace(string(res.Stderr)))
	}
	if strings.TrimSpace(string(res.Stdout)) == metricsMark {
		return "devzone", nil
	}
	return "other", nil
}

// replaceLegacyMetrics removes the legacy objects devzone installed, before the
// chart takes over: the selector of the official manifest is immutable, so the
// Deployment cannot be updated in place. Only the two names of the legacy
// install are deleted, and only when the devzone mark is present. It reports
// whether any legacy object was deleted.
func (m *module) replaceLegacyMetrics() (bool, error) {
	removed := false
	for _, kind := range []string{"deployment", "service"} {
		res, err := m.runner.Run(m.ctx, "kubectl",
			m.kubectlArgs("-n", metricsNS, "delete", kind, "metrics-server",
				"--ignore-not-found", "--wait=true"), fexec.Opts{})
		if err != nil {
			return removed, err
		}
		if res.Code != 0 {
			return removed, fmt.Errorf("metrics-server : legacy %s not removed: %s", kind, strings.TrimSpace(string(res.Stderr)))
		}
		removed = true
	}
	return removed, nil
}

// metricsAdopt prepares kube-system for the Application. When the Application
// already exists it is a rerun: nothing is deleted and no owner is checked.
// Otherwise nothing is done when the Deployment is absent, the legacy devzone
// copy is replaced, and any other installation is refused untouched. It reports
// whether legacy objects were deleted.
func (m *module) metricsAdopt() (bool, error) {
	exists, err := m.metricsApplicationExists()
	if err != nil {
		return false, err
	}
	if exists {
		return false, nil
	}
	owner, err := m.metricsOwner()
	if err != nil {
		return false, err
	}
	switch owner {
	case "":
		return false, nil
	case "devzone":
		removed, err := m.replaceLegacyMetrics()
		if err != nil && removed {
			return true, fmt.Errorf("%w; metrics-server is partly removed, run the command again", err)
		}
		return removed, err
	default:
		return false, fmt.Errorf("metrics-server : already installed in kube-system by another owner: nothing was changed (no deletion, no Application applied); remove that installation or keep it")
	}
}
