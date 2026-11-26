package agent

import (
	"context"
	"strings"
)

// AgentPodEgressMode reads egress mode from the egress-proxy service label
// (#220). Shell agent_pod_egress_mode; kubectl via Runner.
func AgentPodEgressMode(ctx context.Context, r Runner) string {
	if r == nil {
		return ""
	}
	res, err := r.Run(ctx, "kubectl", []string{
		"get", "service", "-l", "app.kubernetes.io/component=egress-proxy",
		"-o", "jsonpath={.items[0].metadata.labels.devzone\\.io/egress-mode}",
	}, Opts{})
	if err != nil {
		return ""
	}
	return string(res.Stdout)
}

// EgressManifestLines returns proxy env lines when mode non-empty. Shell
// agent_pod_egress_manifest_lines.
func EgressManifestLines(mode string) string {
	if mode == "" {
		return ""
	}
	return strings.Join([]string{
		"    - name: HTTP_PROXY",
		`      value: "http://egress-proxy:3128"`,
		"    - name: HTTPS_PROXY",
		`      value: "http://egress-proxy:3128"`,
		"    - name: NO_PROXY",
		`      value: "localhost,127.0.0.1,.svc,.cluster.local"`,
	}, "\n") + "\n"
}

// EgressInitLines returns strict-mode guard initContainer. Shell
// agent_pod_egress_init_lines.
func EgressInitLines(mode, wsImage string) string {
	if mode != "strict" {
		return ""
	}
	args := `i=0; while [ \$i -lt 20 ]; do if ! curl --noproxy "*" -m 3 -sS https://opencode.ai >/dev/null 2>&1; then exit 0; fi; i=\$((i+1)); sleep 1; done; echo "egress restriction never became effective: session refused" >&2; exit 1`
	lines := []string{
		"  initContainers:",
		"  - name: wait-egress-restriction",
		"    image: " + wsImage,
		`    command: ["/bin/bash", "-lc"]`,
		"    args:",
		"    - '" + args + "'",
		"    securityContext:",
		"      runAsUser: 1000",
		"      runAsGroup: 1000",
		"      allowPrivilegeEscalation: false",
		"      capabilities:",
		`        drop: ["ALL"]`,
	}
	return strings.Join(lines, "\n") + "\n"
}
