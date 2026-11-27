package command

import (
	"fmt"
	"io"
)

// workspaceHelp is the help of "devzone workspace", copied line by line from
// the heredoc of manage/workspace.sh so the user sees the same text.
const workspaceHelp = `devzone workspace start|stop|status|shell|ports|services|argocd|update|egress
  start [--image repository:tag]  install workspace (image for devzone version by default)
  update [--version X.Y.Z] [--yes]  move to the latest stable release (or X.Y.Z); the pod is recreated
  ports [start|stop|status]       applications and services from pod on workstation localhost
  services enable|disable <service> [options] | status
                        devzone services (gitlab, postgres, argocd) of the cluster, installed from the workstation
  argocd status | init [--repo <url>|--none] | apply | app add <repo url> [path] [--name N] [--revision R] | app list | app remove <N>
                        Argo CD of the workspace: .argocd.conf, GitOps repository, your projects as Applications
  egress observation|strict|off|status|allow <domain>|deny <domain>   egress proxy of the agent sessions (--pod)
`

// workspaceUnknown refuses a subcommand the shell refused, with its message and
// status. Why: after the port nothing may fall back to bash, so an unknown word
// is answered here instead of being delegated.
func workspaceUnknown(errOut io.Writer, word string) int {
	fmt.Fprintf(errOut, "✖ unknown subcommand: %s (devzone workspace start|stop|status|shell|ports|services|argocd|update)\n", word)
	return 1
}

// workspacePortsUnknown refuses an unknown ports word as ports-workspace.sh did.
func workspacePortsUnknown(errOut io.Writer) int {
	fmt.Fprintln(errOut, "✖ devzone workspace ports start|stop|status")
	return 1
}

// workspaceArgoCDUnknown refuses an unknown argocd word as the shell dispatch did.
func workspaceArgoCDUnknown(errOut io.Writer) int {
	fmt.Fprintln(errOut, "✖ devzone workspace argocd status | init [--repo <url>|--none] | apply | app add <repo url> [path] [--name N] [--revision R] | app list | app remove <N>")
	return 1
}
