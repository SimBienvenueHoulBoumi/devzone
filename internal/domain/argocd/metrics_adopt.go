package argocd

import (
	"fmt"
	"strings"

	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// metricsMark is the label the legacy installer puts on the deployment it
// installed (metrics-server.sh), so devzone only removes its own copy.
const metricsMark = "installe"

// metricsOwner reports who installed the metrics-server deployment of kube-system:
// "" when absent, "devzone" when the legacy installer marked it, "other" otherwise.
func (m *module) metricsOwner() (string, error) {
	res, err := m.runner.Run(m.ctx, "kubectl",
		[]string{"--context", "devzone", "-n", metricsNS, "get", "deployment", "metrics-server",
			"-o", "jsonpath={.metadata.labels.devzone}"}, fexec.Opts{})
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
// install are deleted, and only when the devzone mark is present.
func (m *module) replaceLegacyMetrics() error {
	for _, kind := range []string{"deployment", "service"} {
		res, err := m.runner.Run(m.ctx, "kubectl",
			[]string{"--context", "devzone", "-n", metricsNS, "delete", kind, "metrics-server",
				"--ignore-not-found", "--wait=true"}, fexec.Opts{})
		if err != nil {
			return err
		}
		if res.Code != 0 {
			return fmt.Errorf("metrics-server : legacy %s not removed: %s", kind, strings.TrimSpace(string(res.Stderr)))
		}
	}
	return nil
}

// metricsAdopt prepares kube-system for the Application: nothing when absent,
// the legacy devzone copy replaced, and any other installation left untouched.
func (m *module) metricsAdopt() error {
	owner, err := m.metricsOwner()
	if err != nil {
		return err
	}
	switch owner {
	case "":
		return nil
	case "devzone":
		return m.replaceLegacyMetrics()
	default:
		return fmt.Errorf("metrics-server : already installed in kube-system by another owner, left untouched; remove it or keep it: devzone metrics is not applied")
	}
}
