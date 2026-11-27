package podcmd

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestStatusGitlabPlatform checks the GitLab platform lines and the host used
// for the glab connection, without a real glab binary.
func TestStatusGitlabPlatform(t *testing.T) {
	_, _, stateFile, r := statusFixture(t)
	writeJSONFile(t, stateFile, "platform=gitlab\ngitlab_url=http://gitlab.localhost:8929/\n")
	r.program(nil, 0, "", "gh", "auth", "status")
	glab := filepath.Join(os.Getenv("HOME"), ".local", "bin", "glab")
	r.program(nil, 0, "", glab, "auth", "status", "--hostname", "gitlab.localhost:8929")
	helper := []string{"git", "config", "--global", "--get", "credential.http://gitlab.localhost:8929/.helper"}
	r.program(nil, 0, "!glab auth git-credential\n", helper[0], helper[1:]...)
	contains(t, runStatusText(t, r), "  ✔ platform       gitlab: http://gitlab.localhost:8929/, glab connected",
		"  ✔ git via glab", "  ○ GitHub          not needed here", "simdevWarden/repowarden#531")
	r.program(nil, 1, "", glab, "auth", "status", "--hostname", "gitlab.localhost:8929")
	r.program(nil, 1, "", helper[0], helper[1:]...)
	contains(t, runStatusText(t, r), "  ⚠ platform       gitlab: http://gitlab.localhost:8929/, glab not connected: glab auth login --hostname gitlab.localhost:8929",
		"  ⚠ git via glab    to set: devzone platform gitlab")
}

// TestStatusGitopsAndCatalog checks the GitOps repository line, the pod
// fallback and the catalog summary from the pod launcher.
func TestStatusGitopsAndCatalog(t *testing.T) {
	t.Run("host without repository", func(t *testing.T) {
		_, _, _, r := statusFixture(t)
		contains(t, runStatusText(t, r), "  ○ argocd          no GitOps repository: devzone argocd init")
	})
	t.Run("declared repository", func(t *testing.T) {
		root, _, _, r := statusFixture(t)
		writeJSONFile(t, filepath.Join(root, ".argocd.conf"), "[argocd]\nrepo = https://example.invalid/apps\n")
		contains(t, runStatusText(t, r), "  ○ argocd          GitOps repository: https://example.invalid/apps")
	})
	t.Run("pod fallback", func(t *testing.T) {
		_, script, stateFile, r := statusFixture(t)
		t.Setenv("DEVZONE_WORKSPACE", "kubernetes")
		for _, dns := range []string{
			"gitlab-webservice-default.devzone-gitlab.svc",
			"postgres.devzone-postgres.svc",
			"argocd-server.devzone-argocd.svc",
		} {
			r.program(nil, 1, "", "getent", "hosts", dns)
		}
		r.program([]string{"DEVZONE_STATE=" + stateFile}, 0, "  ○ argocd          managed from the workstation\n", script, "state", "gitops-line")
		contains(t, runStatusText(t, r), "  ○ argocd          managed from the workstation")
	})
	t.Run("catalog", func(t *testing.T) {
		root, script, _, r := statusFixture(t)
		if err := os.MkdirAll(filepath.Join(root, ".devcontainer", "catalog"), 0o755); err != nil {
			t.Fatal(err)
		}
		r.program(nil, 0, "  ○ catalog         no application\n", script, "catalog", "resume")
		contains(t, runStatusText(t, r), "  ○ catalog         no application")
	})
}

// TestStatusGitlabSecret checks the warning shown when the Rails secret of a
// reinstalled GitLab is missing, and its absence when the file is present.
func TestStatusGitlabSecret(t *testing.T) {
	root, _, stateFile, r := statusFixture(t)
	writeJSONFile(t, stateFile, "gitlab=on\n")
	r.program(nil, 0, "", filepath.Join(root, ".devcontainer", "devzone"), "gitlab", "status")
	contains(t, runStatusText(t, r), "  ⚠ gitlab          GitLab reinstalled")
	writeJSONFile(t, filepath.Join(root, "workspace", ".gitlab", "rails-secret.yaml"), "secret\n")
	if out := runStatusText(t, r); strings.Contains(out, "GitLab reinstalled") {
		t.Fatal("warning must disappear when Rails secret exists")
	}
}

// TestStatusClusterWarnings checks the remote cluster, old cluster, internal
// working cluster and RBAC warnings of the summary.
func TestStatusClusterWarnings(t *testing.T) {
	t.Run("remote services cluster", func(t *testing.T) {
		_, script, _, r := statusFixture(t)
		r.program(nil, 0, "remote.example\n", script, "kube", "saved")
		r.program(nil, 1, "", script, "kube", "local", "remote.example")
		contains(t, runStatusText(t, r), "  ⚠ cluster        remote: remote.example — services on a remote cluster")
	})
	t.Run("old instance cluster", func(t *testing.T) {
		_, _, _, r := statusFixture(t)
		t.Setenv("DEVZONE_INSTANCE", "prod")
		r.program(nil, 0, "gitlab-prod\n", "kind", "get", "clusters")
		contains(t, runStatusText(t, r), "  ⚠ old kind-gitlab cluster-prod: devzone gitlab migrate")
	})
	t.Run("internal working cluster", func(t *testing.T) {
		root, script, _, r := statusFixture(t)
		r.program(nil, 0, "kind-devzone\n", "kubectl", "config", "current-context")
		r.program([]string{"KUBECONFIG=" + filepath.Join(root, "host.config")}, 0, "workstation\n", "kubectl", "config", "current-context")
		r.program(nil, 0, "", script, "kube", "reachable", "workstation")
		contains(t, runStatusText(t, r), "  ⚠ working cluster: kind-devzone (devzone internal cluster); go back: devzone use workstation")
	})
	t.Run("rbac", func(t *testing.T) {
		_, _, _, r := statusFixture(t)
		r.program(nil, 0, "yes\n", "kubectl", "auth", "can-i", "--as=system:serviceaccount:default:default", "get", "secrets", "-n", "devzone-postgres")
		contains(t, runStatusText(t, r), "  ⚠ rbac          : access to devzone-postgres secrets not restricted")
	})
}

// TestStatusPortsCredentialsPackages checks the relay, credential and failed
// package lines, including the fallback when the port command cannot answer.
func TestStatusPortsCredentialsPackages(t *testing.T) {
	root, _, stateFile, r := statusFixture(t)
	r.program([]string{"DEVZONE_STATE=" + stateFile}, 0, "2 relays (443, 8443)\n", "devzone", "port", "resume")
	writeJSONFile(t, filepath.Join(root, ".password"), "secret\n")
	writeJSONFile(t, filepath.Join(root, "packages.failed"), "package-a\n\npackage-b\n")
	out := runStatusText(t, r)
	contains(t, out, "  ✔ ports to the workstation 2 relays (443, 8443)",
		"  ○ credentials: "+filepath.Join(root, ".password"),
		"  ⚠ packages         package-a, package-b: devzone packages")
	r.program([]string{"DEVZONE_STATE=" + stateFile}, 1, "failure\n", "devzone", "port", "resume")
	contains(t, runStatusText(t, r), "  ○ ports to the workstation none")
}
