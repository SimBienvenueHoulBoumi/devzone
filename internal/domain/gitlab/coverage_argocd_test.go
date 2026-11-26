package gitlab

import (
	"encoding/base64"
	"os"
	osexec "os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/platform/kube"
)

// TestArgoCDNamespaceAbsentByCode checks that a namespace absent by the exit
// code of kubectl, not only by an error, takes the direct helm path
// (gitlab-argocd.bats "unknown revision").
func TestArgoCDNamespaceAbsentByCode(t *testing.T) {
	f := newFixture(t)
	f.programInstallFull()
	f.writeFile(".devzone.modules", "argocd=on\n")
	f.writeFile("package.json", `{"version": "1.2.3"}`+"\n")
	if err := os.MkdirAll(f.root+"/charts/devzone-gitlab", 0o755); err != nil {
		t.Fatal(err)
	}
	f.r.On("kubectl", []string{"--kubeconfig=" + kube.AdminKubeconfig("devzone-services"),
		"--context", "devzone-services", "get", "namespace", "devzone-argocd"},
		exec.Result{Code: 1})
	if code := f.run("install"); code != 0 {
		t.Fatalf("code = %d, stderr = %q", code, f.errStr())
	}
	if f.hasCall("-n devzone-argocd apply -f -") {
		t.Errorf("Application applied although the namespace is absent: %v", f.calls())
	}
	if !f.hasCall("upgrade --install gitlab") {
		t.Errorf("no direct helm pass: %v", f.calls())
	}
}

// TestApplicationManifestFromConf checks that the Application holds the
// repository designated in .argocd.conf, not a repository written in the Go
// code (gitlab-argocd.bats "Application devzone-gitlab").
func TestApplicationManifestFromConf(t *testing.T) {
	f := newFixture(t)
	f.writeFile(".argocd.conf", "[argocd]\nrepo = https://github.com/x/devzone-argocd.git\n")
	f.writeFile("package.json", `{"version": "1.2.3"}`+"\n")
	r := newRun(nil, f.opts())
	if got := r.gitopsRepo(); got != "https://github.com/x/devzone-argocd.git" {
		t.Errorf("gitopsRepo from .argocd.conf = %q", got)
	}
	if got := r.repoURL(); got != "https://github.com/SimBienvenueHoulBoumi/devzone.git" {
		t.Errorf("default repoURL = %q", got)
	}
	t.Setenv("DEVZONE_REPO_URL", "https://github.com/env/devzone.git")
	if got := r.repoURL(); got != "https://github.com/env/devzone.git" {
		t.Errorf("repoURL = %q, want the environment", got)
	}
	manifest := applicationManifest("devzone-gitlab", r.repoURL(), "v1.2.3",
		"gitlab-runner.gitlabUrl=http://gitlab-webservice-default.devzone-gitlab.svc:8181")
	for _, want := range []string{
		"kind: Application", "name: devzone-gitlab", "namespace: devzone-argocd",
		"repoURL: https://github.com/env/devzone.git", "targetRevision: v1.2.3",
		"path: charts/devzone-gitlab", "namespace: devzone-gitlab",
	} {
		if !strings.Contains(manifest, want) {
			t.Errorf("manifest lacks %q:\n%s", want, manifest)
		}
	}
}

// TestGitOpsWriteUsesConfRepo checks that the GitOps write encodes the
// Application with the repository of .argocd.conf in the API call.
func TestGitOpsWriteUsesConfRepo(t *testing.T) {
	f := newFixture(t)
	f.programInstallFull()
	f.writeFile(".devzone.modules", "argocd=on\n")
	f.writeFile("package.json", `{"version": "1.2.3"}`+"\n")
	f.writeFile(".argocd.conf", "[argocd]\nrepo=https://github.com/x/devzone-argocd.git\n")
	if err := os.MkdirAll(f.root+"/charts/devzone-gitlab", 0o755); err != nil {
		t.Fatal(err)
	}
	f.r.On("gh", nil, exec.Result{})
	if code := f.run("install"); code != 0 {
		t.Fatalf("code = %d, stderr = %q", code, f.errStr())
	}
	for _, call := range f.r.Calls() {
		if call.Name != "gh" {
			continue
		}
		line := strings.Join(call.Args, " ")
		if !strings.Contains(line, "repos/x/devzone-argocd/contents/apps%2Fdevzone-gitlab.yaml") {
			continue
		}
		for _, arg := range call.Args {
			if !strings.HasPrefix(arg, "content=") {
				continue
			}
			manifest, err := base64.StdEncoding.DecodeString(strings.TrimPrefix(arg, "content="))
			if err != nil || !strings.Contains(string(manifest), "repoURL: https://github.com/SimBienvenueHoulBoumi/devzone.git") {
				t.Errorf("GitOps manifest = %q, %v", manifest, err)
			}
			return
		}
	}
	t.Errorf("no GitOps write in %v", f.calls())
}

// TestServicesAdminSeedOnlyGitlab checks the refusal of the seed of another
// service, as the shell entry point of the workspace pod did.
func TestServicesAdminSeedOnlyGitlab(t *testing.T) {
	cmd := osexec.Command("bash", filepath.Join("..", "..", "..", ".devcontainer", "services-admin.sh"), "seed", "postgres")
	out, err := cmd.CombinedOutput()
	if err == nil {
		t.Fatal("code = 0, want 2")
	}
	if exit, ok := err.(*osexec.ExitError); !ok || exit.ExitCode() != 2 {
		t.Fatalf("error = %v", err)
	}
	if !strings.Contains(string(out), "seed: only gitlab") {
		t.Errorf("output = %q", out)
	}
}
