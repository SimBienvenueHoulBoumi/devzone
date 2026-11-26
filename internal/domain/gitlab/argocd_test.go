package gitlab

import (
	"encoding/base64"
	"os"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/platform/kube"
)

// TestInstallArgoCDModuleOn checks the Application path: with the module
// argocd on, the install applies the Application devzone-gitlab and does not
// run the helm pass of GitLab (gitlab-argocd.bats).
func TestInstallArgoCDModuleOn(t *testing.T) {
	f := newFixture(t)
	f.programInstallFull()
	f.writeFile(".devzone.modules", "argocd=on\n")
	f.writeFile("package.json", `{"version": "1.2.3"}`+"\n")
	f.r.On("kubectl", []string{"--kubeconfig=" + kube.AdminKubeconfig("devzone-services"),
		"--context", "devzone-services", "get", "namespace", "devzone-argocd"}, exec.Result{})
	f.r.On("kubectl", []string{"--context", "devzone", "-n", "devzone-argocd", "apply", "-f", "-"}, exec.Result{})
	if err := os.MkdirAll(f.root+"/charts/devzone-gitlab", 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(f.root+"/charts/devzone-gitlab/Chart.yaml", []byte("name: devzone-gitlab\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if code := f.run("install"); code != 0 {
		t.Fatalf("code = %d, stderr = %q", code, f.errStr())
	}
	applied := false
	for _, c := range f.r.Calls() {
		if c.Name == "kubectl" && strings.Join(c.Args, " ") == "--context devzone -n devzone-argocd apply -f -" {
			applied = true
		}
	}
	if !applied {
		t.Errorf("no apply of the Application in calls: %v", f.calls())
	}
	if !f.hasCall("delete secret -l owner=helm,name=gitlab") {
		t.Errorf("no release secret adoption in calls: %v", f.calls())
	}
}

// TestInstallArgoCDUnknownRevision checks the direct helm path on a
// development clone (version 0.0.0, gitlab-argocd.bats).
func TestInstallArgoCDUnknownRevision(t *testing.T) {
	f := newFixture(t)
	f.programInstallFull()
	f.writeFile(".devzone.modules", "argocd=on\n")
	f.writeFile("package.json", `{"version": "0.0.0"}`+"\n")
	if code := f.run("install"); code != 0 {
		t.Fatalf("code = %d, stderr = %q", code, f.errStr())
	}
	if f.hasCall("--context devzone -n devzone-argocd apply") {
		t.Errorf("an Application was applied: %v", f.calls())
	}
	if !f.hasCall("upgrade --install gitlab") {
		t.Errorf("no helm upgrade in calls: %v", f.calls())
	}
}

// TestApplicationManifest checks the Application manifest of the gitlab
// service, generated as application.sh of the devzone repository does.
func TestApplicationManifest(t *testing.T) {
	manifest := applicationManifest("devzone-gitlab", "https://github.com/SimBienvenueHoulBoumi/devzone.git", "v1.2.3",
		"gitlab-runner.gitlabUrl=http://gitlab-webservice-default.devzone-gitlab.svc:8181")
	for _, want := range []string{
		"apiVersion: argoproj.io/v1alpha1",
		"kind: Application",
		"  name: devzone-gitlab",
		"  namespace: devzone-argocd",
		"devzone.io/kind: service",
		"repoURL: https://github.com/SimBienvenueHoulBoumi/devzone.git",
		"targetRevision: v1.2.3",
		"path: charts/devzone-gitlab",
		"        - name: gitlab-runner.gitlabUrl",
		`          value: "http://gitlab-webservice-default.devzone-gitlab.svc:8181"`,
		"namespace: devzone-gitlab",
	} {
		if !strings.Contains(manifest, want) {
			t.Errorf("manifest lacks %q:\n%s", want, manifest)
		}
	}
}

// TestGitopsRepo checks the GitOps repository designated in .argocd.conf
// ([argocd] repo, gitops_repo of gitops.sh).
func TestGitopsRepo(t *testing.T) {
	f := newFixture(t)
	f.writeFile(".argocd.conf", "# Argo CD\n[argocd]\nrepo = https://github.com/x/devzone-argocd.git  # none: direct apply\nprovider = gitlab\n[app other]\nrepo = https://github.com/other.git\n")
	f.writeFile("package.json", `{"version": "0.0.0"}`+"\n")
	r := newRun(nil, f.opts())
	if got := r.gitopsRepo(); got != "https://github.com/x/devzone-argocd.git" {
		t.Errorf("gitopsRepo = %q", got)
	}
	if got := r.gitopsProvider(); got != "gitlab" {
		t.Errorf("gitopsProvider = %q", got)
	}
	f.writeFile(".argocd.conf", "[argocd]\nrepo = none\n")
	if got := r.gitopsRepo(); got != "" {
		t.Errorf("gitopsRepo with none = %q", got)
	}
}

// TestApplicationApplyGitOpsRepo checks the Application written into the
// GitOps repository of .argocd.conf instead of applied directly (Lot B).
func TestApplicationApplyGitOpsRepo(t *testing.T) {
	f := newFixture(t)
	f.programInstallFull()
	f.writeFile(".devzone.modules", "argocd=on\n")
	f.writeFile("package.json", `{"version": "1.2.3"}`+"\n")
	f.writeFile(".argocd.conf", "[argocd]\nrepo=https://github.com/x/devzone-argocd.git\n")
	f.r.On("kubectl", []string{"--kubeconfig=" + kube.AdminKubeconfig("devzone-services"),
		"--context", "devzone-services", "get", "namespace", "devzone-argocd"}, exec.Result{})
	rr := newRun(nil, f.opts())
	content := base64.StdEncoding.EncodeToString([]byte(applicationManifest("devzone-gitlab", rr.repoURL(), "v1.2.3",
		"gitlab-runner.gitlabUrl=http://gitlab-webservice-default.devzone-gitlab.svc:8181")))
	f.r.On("gh", []string{"api", "repos/x/devzone-argocd/contents/apps%2Fdevzone-gitlab.yaml", "--jq", ".sha"},
		exec.Result{Stdout: []byte("abcdef1234567890abcdef1234567890abcdef12\n")})
	f.r.On("gh", []string{"api", "-X", "PUT", "repos/x/devzone-argocd/contents/apps%2Fdevzone-gitlab.yaml",
		"-f", "message=devzone: application devzone-gitlab",
		"-f", "content=" + content, "-f", "sha=abcdef1234567890abcdef1234567890abcdef12"},
		exec.Result{})
	if err := os.MkdirAll(f.root+"/charts/devzone-gitlab", 0o755); err != nil {
		t.Fatal(err)
	}
	if code := f.run("install"); code != 0 {
		t.Fatalf("code = %d, stderr = %q", code, f.errStr())
	}
	if !f.hasCall("repos/x/devzone-argocd/contents/apps%2Fdevzone-gitlab.yaml") {
		t.Errorf("no write to the GitOps repository in calls: %v", f.calls())
	}
	if f.hasCall("--context devzone -n devzone-argocd apply -f -") {
		t.Errorf("the Application was applied directly: %v", f.calls())
	}
}

// TestSeedWritesRunnerSecret checks the call writing the Secret of the chart
// out of Git (gitlab-argocd.bats "seed → Secret gitlab-runner-secret
// written").
func TestSeedWritesRunnerSecret(t *testing.T) {
	f := newFixture(t)
	f.programSeedBase()
	f.r.On("kubectl", nil, exec.Result{})
	testBaseURL = serverOf(t, map[string]string{
		"/api/v4/runners/verify": "200",
		"/api/v4/user/runners":   `{"token":"token-runner"}`,
	}).URL
	t.Cleanup(func() { testBaseURL = "" })
	if code := f.run("seed"); code != 0 {
		t.Fatalf("code = %d, stderr = %q", code, f.errStr())
	}
	if !f.hasCall("create secret generic gitlab-runner-secret") {
		t.Errorf("no secret creation in calls: %v", f.calls())
	}
	if !f.hasCall("--from-literal=runner-registration-token=") {
		t.Errorf("no empty runner-registration-token in calls: %v", f.calls())
	}
	if got := f.readFile("workspace/.gitlab/runner-token"); got != "token-runner" {
		t.Errorf("runner-token = %q", got)
	}
}
