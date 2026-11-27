package gitlab

import (
	"encoding/base64"
	"errors"
	"io"
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
	for _, forbidden := range []string{"delete secret", "delete pvc", "delete namespace"} {
		if f.hasCall(forbidden) {
			t.Errorf("data was removed during adoption (%s): %v", forbidden, f.calls())
		}
	}
	if f.hasCall("upgrade --install gitlab") {
		t.Errorf("helm direct was used with Argo CD on: %v", f.calls())
	}
}

// TestInstallArgoCDUnknownRevisionFails checks that a development clone with
// no usable revision fails before installing anything, with no helm fallback.
func TestInstallArgoCDUnknownRevisionFails(t *testing.T) {
	f := newFixture(t)
	f.programInstallFull()
	f.writeFile(".devzone.modules", "argocd=on\n")
	f.writeFile("package.json", `{"version": "0.0.0"}`+"\n")
	if err := os.MkdirAll(f.root+"/charts/devzone-gitlab", 0o755); err != nil {
		t.Fatal(err)
	}
	f.writeFile("charts/devzone-gitlab/Chart.yaml", "name: devzone-gitlab\n")
	f.r.On("kubectl", []string{"--kubeconfig=" + kube.AdminKubeconfig("devzone-services"),
		"--context", "devzone-services", "get", "namespace", "devzone-argocd"}, exec.Result{})
	f.r.OnError("git", []string{"ls-remote", "--tags", "--refs", "https://github.com/SimBienvenueHoulBoumi/devzone.git"},
		exec.Result{}, errors.New("network unreachable"))
	if code := f.run("install"); code == 0 {
		t.Fatalf("install succeeded without a revision: %v / %q", f.calls(), f.outStr())
	}
	if !strings.Contains(f.errStr(), "cannot list the tags") || !strings.Contains(f.errStr(), "DEVZONE_ARGOCD_REVISION") {
		t.Fatalf("unclear failure: %q", f.errStr())
	}
	if f.hasCall("apply -f -") || f.hasCall("upgrade --install gitlab") {
		t.Errorf("partial installation after a revision failure: %v", f.calls())
	}
}

// TestInstallArgoCDPublishedTag checks that a development clone adopts the
// newest published tag containing the chart instead of installing with helm.
func TestInstallArgoCDPublishedTag(t *testing.T) {
	f := newFixture(t)
	f.programInstallFull()
	f.writeFile(".devzone.modules", "argocd=on\n")
	f.writeFile("package.json", `{"version": "0.0.0"}`+"\n")
	if err := os.MkdirAll(f.root+"/charts/devzone-gitlab", 0o755); err != nil {
		t.Fatal(err)
	}
	f.writeFile("charts/devzone-gitlab/Chart.yaml", "name: devzone-gitlab\n")
	f.r.On("kubectl", []string{"--kubeconfig=" + kube.AdminKubeconfig("devzone-services"),
		"--context", "devzone-services", "get", "namespace", "devzone-argocd"}, exec.Result{})
	repo := "https://github.com/SimBienvenueHoulBoumi/devzone.git"
	f.r.On("git", []string{"ls-remote", "--tags", "--refs", repo}, exec.Result{
		Stdout: []byte("sha\trefs/tags/v9.0.0\nsha\trefs/tags/v2.1.0\n"),
	})
	f.r.On("gh", []string{"api", "repos/SimBienvenueHoulBoumi/devzone/contents/charts/devzone-gitlab?ref=v9.0.0", "--jq", ".type"}, exec.Result{Code: 1})
	f.r.On("gh", []string{"api", "repos/SimBienvenueHoulBoumi/devzone/contents/charts/devzone-gitlab?ref=v2.1.0", "--jq", ".type"}, exec.Result{Stdout: []byte("dir\n")})
	f.r.On("kubectl", []string{"--context", "devzone", "-n", "devzone-argocd", "apply", "-f", "-"}, exec.Result{})
	if code := f.run("install"); code != 0 {
		t.Fatalf("code = %d, stderr = %q", code, f.errStr())
	}
	manifest := ""
	for _, c := range f.r.Calls() {
		if c.Name == "kubectl" && strings.Join(c.Args, " ") == "--context devzone -n devzone-argocd apply -f -" && c.Opts.Stdin != nil {
			data, err := io.ReadAll(c.Opts.Stdin)
			if err != nil {
				t.Fatal(err)
			}
			manifest = string(data)
		}
	}
	if !strings.Contains(manifest, "targetRevision: v2.1.0") {
		t.Errorf("the published tag was not used: %s / %v", manifest, f.calls())
	}
	if f.hasCall("upgrade --install gitlab") {
		t.Errorf("helm direct was used with Argo CD on: %v", f.calls())
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
