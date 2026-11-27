package command

import (
	"bytes"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
)

func TestUninstallRemovesTemporaryAccountByName(t *testing.T) {
	root := devzoneDir(t, "cluster=kind-devzone-ci")
	runner := fake.New()
	registerHostProbe(t, runner, root)
	registerLists(t, runner, "kind-devzone-ci", "", "", "devzone-workspace/devzone-services-admin\n")
	runner.On("kubectl", []string{"--context", "kind-devzone-ci", "-n", "devzone-workspace", "delete", "serviceaccount", "devzone-services-admin", "--ignore-not-found"}, exec.Result{})
	chdir(t, root)
	var out, errOut bytes.Buffer
	code := uninstallCommand(&cli.Context{Args: []string{"--yes"}, Out: &out, Err: &errOut, Stdin: strings.NewReader(""), Runner: runner})
	if code != 0 {
		t.Fatalf("code = %d, want 0; err=%s", code, errOut.String())
	}
	if !strings.Contains(out.String(), "temporary account removed: devzone-workspace/devzone-services-admin") {
		t.Fatalf("temporary account not removed:\n%s", out.String())
	}
	assertContextCalls(t, runner, "kind-devzone-ci")
}

func TestUninstallDefaultOwnsAppNamespaces(t *testing.T) {
	root := devzoneDir(t, "cluster=kind-devzone-ci")
	runner := fake.New()
	registerHostProbe(t, runner, root)
	registerLists(t, runner, "kind-devzone-ci", "devzone-app-demo\ndevzone-gitlab-mon\n", "devzone-argocd/app-1\n", "")
	runner.On("kubectl", []string{"--context", "kind-devzone-ci", "delete", "namespace", "devzone-app-demo", "--ignore-not-found"}, exec.Result{})
	runner.On("kubectl", []string{"--context", "kind-devzone-ci", "-n", "devzone-argocd", "delete", "application.argoproj.io", "app-1", "--ignore-not-found"}, exec.Result{})
	chdir(t, root)
	var out, errOut bytes.Buffer
	code := uninstallCommand(&cli.Context{Args: []string{"--yes"}, Out: &out, Err: &errOut, Stdin: strings.NewReader(""), Runner: runner})
	if code != 0 {
		t.Fatalf("code = %d, want 0; err=%s", code, errOut.String())
	}
	var deletedAppNS, deletedForeign bool
	for _, c := range runner.Calls() {
		if c.Name != "kubectl" {
			continue
		}
		joined := strings.Join(c.Args, " ")
		if strings.Contains(joined, "delete namespace devzone-app-demo") {
			deletedAppNS = true
		}
		if strings.Contains(joined, "devzone-gitlab-mon") {
			deletedForeign = true
		}
	}
	if !deletedAppNS {
		t.Fatalf("devzone-app-demo not deleted:\n%s", out.String())
	}
	if deletedForeign {
		t.Fatal("namespace of another instance deleted")
	}
	assertContextCalls(t, runner, "kind-devzone-ci")
}

func TestUninstallKeepsUnrecognizedObjects(t *testing.T) {
	root := devzoneDir(t, "cluster=kind-devzone-ci")
	runner := fake.New()
	registerHostProbe(t, runner, root)
	registerLists(t, runner, "kind-devzone-ci", "custom-ns\ndevzone-workspace\ndevzone-workspace-mon\n", "", "")
	runner.On("kubectl", []string{"--context", "kind-devzone-ci", "delete", "namespace", "devzone-workspace", "--ignore-not-found"}, exec.Result{})
	chdir(t, root)
	var out, errOut bytes.Buffer
	code := uninstallCommand(&cli.Context{Args: []string{"--yes"}, Out: &out, Err: &errOut, Stdin: strings.NewReader(""), Runner: runner})
	if code != 0 {
		t.Fatalf("code = %d, want 0; err=%s", code, errOut.String())
	}
	if !strings.Contains(out.String(), "namespace/custom-ns") {
		t.Fatalf("unrecognized object not reported as kept:\n%s", out.String())
	}
	for _, c := range runner.Calls() {
		if c.Name != "kubectl" {
			continue
		}
		joined := strings.Join(c.Args, " ")
		if strings.Contains(joined, "custom-ns") || strings.Contains(joined, "workspace-mon") {
			t.Fatalf("object kept but deleted: %v", c.Args)
		}
	}
	assertContextCalls(t, runner, "kind-devzone-ci")
}
