package workspace

import (
	"fmt"
	"io"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/config"
)

// Names of the workspace release and of its Argo CD namespace and Application,
// as manage/workspace.sh and manage/scripts/workspace/argocd-workspace.sh have them.
const (
	releaseName = "devzone-workspace"
	argocdNS    = config.NamespaceArgoCD
	argocdApp   = "devzone-workspace"
)

// AppRemover takes the Application name out of the GitOps repository and
// refreshes the root Application, as gitops_delete_application does before its
// cluster delete. A non-zero status means the repository refused the removal.
type AppRemover func(name string) int

// Stop removes the workspace from the cluster, as stop_workspace does in
// manage/workspace.sh. The port watcher is stopped first in every case, as the
// shell did before calling the Go command. When Argo CD holds the workspace,
// the Application file leaves the GitOps repository first (remove), then the
// Application is deleted, which removes the pod while the volumes stay. A
// refused removal stops here with status 1 and the Application is kept, so the
// root Application never recreates it. Otherwise the helm release is uninstalled
// and the status of helm is returned.
func Stop(r Runner, remove AppRemover, out, errOut io.Writer) int {
	stopPorts()
	if argocdHoldsWorkspace(r) {
		fmt.Fprintln(out, "▶ Application devzone-workspace deleted (Argo CD removes the pod, the volumes stay)…")
		if code := remove(argocdApp); code != 0 {
			return code
		}
		status, err := r.Kubectl(append(contextFlag(r), "-n", argocdNS, "delete", "application.argoproj.io", argocdApp, "--ignore-not-found", "--wait=true"), nil, out, errOut)
		if err != nil {
			return notStarted
		}
		return status
	}
	return uninstallRelease(r, out, errOut)
}

// argocdHoldsWorkspace reports whether the Argo CD namespace exists and holds
// the workspace Application (argocd_installed and argocd_application_exists).
func argocdHoldsWorkspace(r Runner) bool {
	if !kubectlSucceeds(r, "get", "namespace", argocdNS) {
		return false
	}
	return kubectlSucceeds(r, "-n", argocdNS, "get", "application.argoproj.io", argocdApp)
}

// kubectlSucceeds runs kubectl with the devzone context flag and args, output
// discarded, and reports whether it exited with status 0 (the ak calls of the bash).
func kubectlSucceeds(r Runner, args ...string) bool {
	status, err := r.Kubectl(append(contextFlag(r), args...), nil, io.Discard, io.Discard)
	return err == nil && status == 0
}

// uninstallRelease runs helm uninstall of the workspace release, with its output
// and status (workspace_undeploy). A helm that cannot start gives 127, as a shell does.
func uninstallRelease(r Runner, out, errOut io.Writer) int {
	args := append(helmContextFlag(r), "uninstall", releaseName, "--namespace", namespace)
	status, err := r.Helm(args, nil, out, errOut)
	if err != nil {
		fmt.Fprintf(errOut, "devzone: cannot start helm: %v\n", err)
		return notStarted
	}
	return status
}
