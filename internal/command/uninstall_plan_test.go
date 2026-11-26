package command

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
)

func TestUninstallIgnoresMissingArgoCRD(t *testing.T) {
	root := devzoneDir(t, "cluster=kind-devzone-ci")
	runner := fake.New()
	runner.On("kubectl", nsArgs("kind-devzone-ci"), exec.Result{})
	runner.On("kubectl", appsArgs("kind-devzone-ci"), exec.Result{
		Code:   1,
		Stderr: []byte(`error: the server doesn't have a resource type "applications.argoproj.io"`),
	})
	runner.On("kubectl", saArgs("kind-devzone-ci"), exec.Result{})
	chdir(t, root)
	var out, errOut bytes.Buffer
	code := uninstallCommand(&cli.Context{Args: []string{"--yes"}, Out: &out, Err: &errOut, Stdin: strings.NewReader(""), Runner: runner})
	if code != 0 {
		t.Fatalf("code = %d, want 0; err=%s", code, errOut.String())
	}
	if _, err := os.Stat(filepath.Join(root, ".devzone.modules")); !os.IsNotExist(err) {
		t.Fatalf("state file should be removed, err=%v", err)
	}
}

func TestUninstallKeepsFilesWhenClusterDeleteFails(t *testing.T) {
	root := devzoneDir(t, "cluster=kind-devzone-ci")
	runner := fake.New()
	registerLists(t, runner, "kind-devzone-ci", "devzone-workspace\n", "", "")
	runner.On("kubectl", []string{"--context", "kind-devzone-ci", "delete", "namespace", "devzone-workspace", "--ignore-not-found"}, exec.Result{
		Code:   1,
		Stderr: []byte(`Error from server (Conflict): namespaces "devzone-workspace" is being terminated`),
	})
	chdir(t, root)
	var out, errOut bytes.Buffer
	code := uninstallCommand(&cli.Context{Args: []string{"--yes"}, Out: &out, Err: &errOut, Stdin: strings.NewReader(""), Runner: runner})
	if code != 1 {
		t.Fatalf("code = %d, want 1; out=%s", code, out.String())
	}
	if _, err := os.Stat(filepath.Join(root, ".devzone.modules")); err != nil {
		t.Fatalf("files removed although a cluster deletion failed: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, "workspace")); err != nil {
		t.Fatalf("workspace: %v", err)
	}
}

func TestUninstallWarnsAboutPodVolumes(t *testing.T) {
	root := devzoneDir(t, "cluster=kind-devzone-ci")
	runner := fake.New()
	registerLists(t, runner, "kind-devzone-ci", "devzone-workspace\n", "", "")
	runner.On("kubectl", []string{"--context", "kind-devzone-ci", "delete", "namespace", "devzone-workspace", "--ignore-not-found"}, exec.Result{})
	chdir(t, root)
	var out, errOut bytes.Buffer
	code := uninstallCommand(&cli.Context{Args: []string{"--yes"}, Out: &out, Err: &errOut, Stdin: strings.NewReader(""), Runner: runner})
	if code != 0 {
		t.Fatalf("code = %d, want 0; err=%s", code, errOut.String())
	}
	if !strings.Contains(out.String(), "namespace devzone-workspace holds the pod volumes: deleting it loses the pod data.") {
		t.Fatalf("missing pod volumes warning:\n%s", out.String())
	}
}

func TestUninstallRefusesWithoutConfirmation(t *testing.T) {
	root := devzoneDir(t, "cluster=kind-devzone-ci")
	runner := fake.New()
	registerLists(t, runner, "kind-devzone-ci", "devzone-workspace\n", "", "")
	chdir(t, root)
	var out, errOut bytes.Buffer
	code := uninstallCommand(&cli.Context{Args: nil, Out: &out, Err: &errOut, Stdin: strings.NewReader(""), Runner: runner})
	if code != 1 {
		t.Fatalf("code = %d, want 1; err=%s", code, errOut.String())
	}
	if !strings.Contains(errOut.String(), "devzone uninstall --yes") {
		t.Fatalf("stderr = %q", errOut.String())
	}
	if _, err := os.Stat(filepath.Join(root, ".devzone.modules")); err != nil {
		t.Fatalf("state file removed without confirmation: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, "workspace")); err != nil {
		t.Fatalf("workspace removed: %v", err)
	}
	for _, c := range runner.Calls() {
		if c.Name != "kubectl" {
			continue
		}
		for _, a := range c.Args {
			if a == "delete" {
				t.Fatalf("delete called without confirmation: %v", c.Args)
			}
		}
	}
}

func TestUninstallKeepsWorkspace(t *testing.T) {
	root := devzoneDir(t, "cluster=kind-devzone-ci")
	if err := os.WriteFile(filepath.Join(root, "workspace", "keep.txt"), []byte("keep"), 0o644); err != nil {
		t.Fatal(err)
	}
	runner := fake.New()
	registerLists(t, runner, "kind-devzone-ci", "", "", "")
	chdir(t, root)
	var out, errOut bytes.Buffer
	code := uninstallCommand(&cli.Context{Args: []string{"--yes"}, Out: &out, Err: &errOut, Stdin: strings.NewReader(""), Runner: runner})
	if code != 0 {
		t.Fatalf("code = %d, err=%s", code, errOut.String())
	}
	if _, err := os.Stat(filepath.Join(root, "workspace", "keep.txt")); err != nil {
		t.Fatalf("workspace file removed: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, ".devzone.modules")); !os.IsNotExist(err) {
		t.Fatalf("state file should be removed, err=%v", err)
	}
	assertContextCalls(t, runner, "kind-devzone-ci")
}

func TestUninstallKeepsOtherInstance(t *testing.T) {
	root := devzoneDir(t, "cluster=kind-devzone-ci")
	t.Setenv("DEVZONE_INSTANCE", "mon-devzone")
	runner := fake.New()
	registerLists(t, runner, "kind-devzone-ci", "devzone-workspace-mon-devzone\ndevzone-workspace-other\n", "", "")
	runner.On("kubectl", []string{"--context", "kind-devzone-ci", "delete", "namespace", "devzone-workspace-mon-devzone", "--ignore-not-found"}, exec.Result{})
	chdir(t, root)
	var out, errOut bytes.Buffer
	code := uninstallCommand(&cli.Context{Args: []string{"--yes"}, Out: &out, Err: &errOut, Stdin: strings.NewReader(""), Runner: runner})
	if code != 0 {
		t.Fatalf("code = %d, err=%s", code, errOut.String())
	}
	for _, c := range runner.Calls() {
		if c.Name != "kubectl" {
			continue
		}
		for _, a := range c.Args {
			if strings.Contains(a, "other") {
				t.Fatalf("deleted other instance object: %v", c.Args)
			}
		}
	}
	assertContextCalls(t, runner, "kind-devzone-ci")
}
