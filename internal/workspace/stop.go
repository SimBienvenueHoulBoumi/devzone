package workspace

import (
	"fmt"
	"io"
	"os/exec"
	"strings"
)

// Names of the workspace release and of its Argo CD namespace and Application,
// as manage/workspace.sh and manage/scripts/workspace/argocd-workspace.sh have them.
const (
	releaseName = "devzone-workspace"
	argocdNS    = "devzone-argocd"
	argocdApp   = "devzone-workspace"
)

// Stop removes the workspace from the cluster, as stop_workspace does in
// manage/workspace.sh. When Argo CD holds the workspace (its Application
// exists), the Application is deleted, which removes the pod while the
// volumes stay. Otherwise the port watcher is stopped, then the helm release
// is uninstalled, and the status of helm is returned.
func Stop(r Runner, out, errOut io.Writer) int {
	if argocdHoldsWorkspace(r) {
		fmt.Fprintln(out, "▶ Application devzone-workspace deleted (Argo CD removes the pod, the volumes stay)…")
		// When a GitOps repository is designated, its file is removed first so
		// the root Application never recreates the child.
		repo := confValue(".argocd.conf", "argocd", "repo")
		if repo != "" && repo != "none" {
			slug := strings.TrimSuffix(strings.TrimPrefix(repo, "https://github.com/"), ".git")
			path := "repos/" + slug + "/contents/apps/devzone-workspace.yaml"
			shaCmd := exec.Command("gh", "api", path, "--jq", ".sha")
			shaOut, _ := shaCmd.Output()
			sha := strings.TrimSpace(string(shaOut))
			args := []string{"api", "-X", "DELETE", path, "-f", "message=devzone: application devzone-workspace removed"}
			if sha != "" {
				args = append(args, "-f", "sha="+sha)
			}
			_ = exec.Command("gh", args...).Run()
		}
		status, err := r.Kubectl(append(contextFlag(r), "-n", argocdNS, "delete", "application.argoproj.io", argocdApp, "--ignore-not-found", "--wait=true"), nil, out, errOut)
		if err != nil {
			return notStarted
		}
		return status
	}
	stopPorts()
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

// helmContextFlag returns the helm arguments that select the devzone context when
// the kubeconfig declares it, and none otherwise (helm_flag in manage/workspace.sh).
func helmContextFlag(r Runner) []string {
	if !declaresDevzone(r) {
		return nil
	}
	return []string{"--kube-context", kubeContext}
}
