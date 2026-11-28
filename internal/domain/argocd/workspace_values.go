package argocd

import rule "github.com/SimBienvenueHoulBoumi/devzone/internal/platform/argocd"

// workspaceValuesContent is written once to the GitOps repository. Every
// tunable key stays commented out with the default of the shipped chart, so
// the user can choose which settings to keep under version control.
const workspaceValuesContent = `# Values of the devzone-workspace chart, read by Argo CD from this GitOps
# repository. devzone creates this file once and never rewrites it: edit the
# keys below to change the liveness probe or the memory of the workspace pod.
# The defaults are kept as comments; uncomment only what you want to change.

# livenessProbe.thresholdPercent: 85 (allowed range: 50 to 95)
# livenessProbe.periodSeconds: 60
# livenessProbe.failureThreshold: 5
# livenessProbe.initialDelaySeconds: 120
# resources.limits.memory: 8Gi
# resources.requests.memory: 4Gi
`

// ensureWorkspaceValuesFile creates the workspace values file only when the
// GitOps repository does not have it yet. Only the blob sha is read, never the
// content, so a file changed by the user is left byte for byte untouched.
func (m *module) ensureWorkspaceValuesFile() int {
	if !m.gitopsEnabled() {
		return 0
	}
	sha, ok := m.gitopsSHA(rule.WorkspaceValuesPath)
	if !ok {
		return 1
	}
	if sha != "" {
		return 0
	}
	return m.gitopsPutText(rule.WorkspaceValuesPath, workspaceValuesContent, "devzone: values devzone-workspace")
}
