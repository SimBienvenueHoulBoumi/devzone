package command

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
)

func TestUninstallKeepsUnsuffixedForNamedInstance(t *testing.T) {
	root := devzoneDir(t, "cluster=kind-devzone-ci")
	t.Setenv("DEVZONE_INSTANCE", "mon")
	runner := fake.New()
	registerLists(t, runner, "kind-devzone-ci", "devzone-workspace\ndevzone-gitlab-mon\n", "", "")
	runner.On("kubectl", []string{"--context", "kind-devzone-ci", "delete", "namespace", "devzone-gitlab-mon", "--ignore-not-found"}, exec.Result{})
	chdir(t, root)
	var out, errOut bytes.Buffer
	code := uninstallCommand(&cli.Context{Args: []string{"--yes"}, Out: &out, Err: &errOut, Stdin: strings.NewReader(""), Runner: runner})
	if code != 0 {
		t.Fatalf("code = %d, want 0; err=%s", code, errOut.String())
	}
	if !strings.Contains(out.String(), "namespace/devzone-workspace") {
		t.Fatalf("shared namespace not reported as kept:\n%s", out.String())
	}
	if strings.Contains(out.String(), "holds the pod volumes") {
		t.Fatalf("pod volumes warning although the namespace is kept:\n%s", out.String())
	}
	for _, c := range runner.Calls() {
		if c.Name != "kubectl" {
			continue
		}
		joined := strings.Join(c.Args, " ")
		if strings.Contains(joined, "delete namespace devzone-workspace") {
			t.Fatalf("unsuffixed namespace deleted by a named instance: %v", c.Args)
		}
	}
	assertContextCalls(t, runner, "kind-devzone-ci")
}

func TestBelongsToInstance(t *testing.T) {
	cases := []struct {
		name     string
		instance string
		ours     bool
		doubt    bool
	}{
		{"devzone-workspace", "devzone", true, false},
		{"devzone-app-demo", "devzone", true, false},
		{"app-1", "devzone", true, false},
		{"devzone", "devzone", true, false},
		{"devzone-gitlab-mon", "devzone", false, false},
		{"custom-ns", "devzone", false, true},
		{"devzone-gitlab-mon", "mon", true, false},
		{"devzone-workspace-mon-devzone", "mon-devzone", true, false},
		{"devzone-workspace", "mon", false, true},
		{"devzone-app-demo", "mon", false, true},
		{"devzone-gitlab-other", "mon", false, false},
		{"custom-ns", "mon", false, true},
	}
	for _, c := range cases {
		ours, doubt := belongsToInstance(c.name, c.instance)
		if ours != c.ours || doubt != c.doubt {
			t.Errorf("belongsToInstance(%q, %q) = (%v, %v), want (%v, %v)",
				c.name, c.instance, ours, doubt, c.ours, c.doubt)
		}
	}
}

func TestCollectUninstallPlanStopsWhenClusterUnreachable(t *testing.T) {
	root := devzoneDir(t, "cluster=kind-devzone-ci")
	if err := os.WriteFile(filepath.Join(root, ".devzone.log"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	runner := fake.New()
	runner.SetErr("kubectl", nsArgs("kind-devzone-ci"), exec.Result{}, context.DeadlineExceeded)
	runner.On("kubectl", appsArgs("kind-devzone-ci"), exec.Result{})
	runner.On("kubectl", saArgs("kind-devzone-ci"), exec.Result{})
	plan, err := collectUninstallPlan(context.Background(), runner, root, "devzone")
	if err == nil {
		t.Fatalf("want an error when a list fails, got plan: %+v", plan)
	}
}
