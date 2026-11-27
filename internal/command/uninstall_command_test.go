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

func TestUninstallRefusesOutsideDevzoneFolder(t *testing.T) {
	root := t.TempDir()
	t.Setenv("DEVZONE_INSTANCE", "")
	t.Setenv("DEVZONE_VOLUMES", "")
	t.Setenv("DEVZONE_ROOT", "")
	runner := fake.New()
	registerHostProbe(t, runner, root)
	chdir(t, root)
	var out, errOut bytes.Buffer
	code := uninstallCommand(&cli.Context{Args: nil, Out: &out, Err: &errOut, Stdin: strings.NewReader(""), Runner: runner})
	if code != 1 {
		t.Fatalf("code = %d, want 1", code)
	}
	if !strings.Contains(errOut.String(), "Not a devzone folder") {
		t.Fatalf("stderr = %q (want the English message)", errOut.String())
	}
}

func TestUninstallRejectsUnknownOption(t *testing.T) {
	root := devzoneDir(t)
	runner := fake.New()
	registerHostProbe(t, runner, root)
	chdir(t, root)
	var out, errOut bytes.Buffer
	code := uninstallCommand(&cli.Context{Args: []string{"--bogus"}, Out: &out, Err: &errOut, Stdin: strings.NewReader(""), Runner: runner})
	if code != 1 {
		t.Fatalf("code = %d, want 1", code)
	}
	if !strings.Contains(errOut.String(), "unknown option: --bogus") {
		t.Fatalf("stderr = %q (want the English message)", errOut.String())
	}
}

func TestUninstallTargetsServicesClusterContext(t *testing.T) {
	root := devzoneDir(t, "cluster=kind-devzone-ci")
	runner := fake.New()
	registerHostProbe(t, runner, root)
	registerLists(t, runner, "kind-devzone-ci", "devzone-workspace\n", "", "")
	runner.On("kubectl", []string{"--context", "kind-devzone-ci", "delete", "namespace", "devzone-workspace", "--ignore-not-found"}, exec.Result{})
	chdir(t, root)
	var out, errOut bytes.Buffer
	code := uninstallCommand(&cli.Context{Args: []string{"--yes"}, Out: &out, Err: &errOut, Stdin: strings.NewReader(""), Runner: runner})
	if code != 0 {
		t.Fatalf("code = %d, want 0; err=%s", code, errOut.String())
	}
	if !strings.Contains(out.String(), "Services cluster context: kind-devzone-ci") {
		t.Fatalf("plan does not show the services cluster context:\n%s", out.String())
	}
	assertContextCalls(t, runner, "kind-devzone-ci")
}

func TestUninstallSkipsKubernetesWithoutServicesCluster(t *testing.T) {
	root := devzoneDir(t)
	runner := fake.New()
	registerHostProbe(t, runner, root)
	runner.On("kubectl", []string{"config", "get-contexts", "-o", "name"}, exec.Result{Stdout: []byte("minikube\n")})
	chdir(t, root)
	var out, errOut bytes.Buffer
	code := uninstallCommand(&cli.Context{Args: []string{"--yes"}, Out: &out, Err: &errOut, Stdin: strings.NewReader(""), Runner: runner})
	if code != 0 {
		t.Fatalf("code = %d, want 0; out=%s err=%s", code, out.String(), errOut.String())
	}
	if !strings.Contains(out.String(), "no devzone services cluster identified") {
		t.Fatalf("plan does not say the Kubernetes part was skipped:\n%s", out.String())
	}
	if _, err := os.Stat(filepath.Join(root, "workspace")); err != nil {
		t.Fatalf("workspace: %v", err)
	}
}

func TestUninstallUsesDevzoneContextWhenDeclared(t *testing.T) {
	root := devzoneDir(t)
	runner := fake.New()
	registerHostProbe(t, runner, root)
	runner.On("kubectl", []string{"config", "get-contexts", "-o", "name"}, exec.Result{Stdout: []byte("minikube\ndevzone\n")})
	registerLists(t, runner, "devzone", "devzone-workspace\n", "", "")
	runner.On("kubectl", []string{"--context", "devzone", "delete", "namespace", "devzone-workspace", "--ignore-not-found"}, exec.Result{})
	chdir(t, root)
	var out, errOut bytes.Buffer
	code := uninstallCommand(&cli.Context{Args: []string{"--yes"}, Out: &out, Err: &errOut, Stdin: strings.NewReader(""), Runner: runner})
	if code != 0 {
		t.Fatalf("code = %d, want 0; err=%s", code, errOut.String())
	}
	if !strings.Contains(out.String(), "Services cluster context: devzone") {
		t.Fatalf("plan does not show the devzone context:\n%s", out.String())
	}
	assertContextCalls(t, runner, "devzone")
}

func TestUninstallStopsOnNamespaceListError(t *testing.T) {
	root := devzoneDir(t, "cluster=kind-devzone-ci")
	runner := fake.New()
	registerHostProbe(t, runner, root)
	runner.SetErr("kubectl", nsArgs("kind-devzone-ci"), exec.Result{}, context.DeadlineExceeded)
	runner.On("kubectl", appsArgs("kind-devzone-ci"), exec.Result{})
	runner.On("kubectl", saArgs("kind-devzone-ci"), exec.Result{})
	chdir(t, root)
	var out, errOut bytes.Buffer
	code := uninstallCommand(&cli.Context{Args: []string{"--yes"}, Out: &out, Err: &errOut, Stdin: strings.NewReader(""), Runner: runner})
	if code != 1 {
		t.Fatalf("code = %d, want 1; out=%s", code, out.String())
	}
	if !strings.Contains(errOut.String(), "get namespaces") {
		t.Fatalf("stderr does not name the failing list: %q", errOut.String())
	}
	if _, err := os.Stat(filepath.Join(root, ".devzone.modules")); err != nil {
		t.Fatalf("files removed after a list error: %v", err)
	}
	assertNoDelete(t, runner)
}

func TestUninstallStopsOnApplicationListError(t *testing.T) {
	root := devzoneDir(t, "cluster=kind-devzone-ci")
	runner := fake.New()
	registerHostProbe(t, runner, root)
	runner.On("kubectl", nsArgs("kind-devzone-ci"), exec.Result{})
	runner.SetErr("kubectl", appsArgs("kind-devzone-ci"), exec.Result{}, context.DeadlineExceeded)
	runner.On("kubectl", saArgs("kind-devzone-ci"), exec.Result{})
	chdir(t, root)
	var out, errOut bytes.Buffer
	code := uninstallCommand(&cli.Context{Args: []string{"--yes"}, Out: &out, Err: &errOut, Stdin: strings.NewReader(""), Runner: runner})
	if code != 1 {
		t.Fatalf("code = %d, want 1; out=%s", code, out.String())
	}
	if !strings.Contains(errOut.String(), "applications.argoproj.io") {
		t.Fatalf("stderr does not name the failing list: %q", errOut.String())
	}
	if _, err := os.Stat(filepath.Join(root, ".devzone.modules")); err != nil {
		t.Fatalf("files removed after a list error: %v", err)
	}
	assertNoDelete(t, runner)
}
