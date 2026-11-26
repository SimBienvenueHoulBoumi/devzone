package command

import (
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
)

// devzoneDir creates a devzone folder with .devcontainer/, workspace/ and a
// state file holding the given lines, and clears the instance environment so
// an ambient value cannot change the instance name of the test.
func devzoneDir(t *testing.T, stateLines ...string) string {
	t.Helper()
	root := t.TempDir()
	for _, dir := range []string{".devcontainer", "workspace"} {
		if err := os.Mkdir(filepath.Join(root, dir), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if len(stateLines) > 0 {
		data := strings.Join(stateLines, "\n") + "\n"
		if err := os.WriteFile(filepath.Join(root, ".devzone.modules"), []byte(data), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("DEVZONE_INSTANCE", "")
	t.Setenv("DEVZONE_VOLUMES", "")
	t.Setenv("DEVZONE_ROOT", "")
	previous, previousExists := commandPortsDisable, commandPortsAutoStartExists
	commandPortsDisable = func(io.Writer, io.Writer) int { return 0 }
	commandPortsAutoStartExists = func() bool { return true }
	t.Cleanup(func() {
		commandPortsDisable, commandPortsAutoStartExists = previous, previousExists
	})
	return root
}

// chdir runs the test inside dir and restores the previous working directory.
func chdir(t *testing.T, dir string) {
	t.Helper()
	old, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chdir(dir); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chdir(old) })
}

// nsArgs is the kubectl call listing the labeled namespaces on kubeCtx.
func nsArgs(kubeCtx string) []string {
	return []string{"--context", kubeCtx, "get", "namespaces", "-l", managedByLabel, "-o", `jsonpath={range .items[*]}{.metadata.name}{"\n"}{end}`}
}

// appsArgs is the kubectl call listing the labeled Argo CD Applications.
func appsArgs(kubeCtx string) []string {
	return []string{"--context", kubeCtx, "get", "applications.argoproj.io", "-A", "-l", managedByLabel, "-o", `jsonpath={range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}`}
}

// saArgs is the kubectl call listing the temporary accounts by name on kubeCtx:
// they carry no label, so they are found by name alone.
func saArgs(kubeCtx string) []string {
	return []string{"--context", kubeCtx, "get", "serviceaccounts", "-A", "--field-selector", "metadata.name=devzone-services-admin", "-o", `jsonpath={range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}`}
}

// registerLists programs the three list calls of the plan against kubeCtx with
// the given answers.
func registerLists(t *testing.T, runner *fake.Runner, kubeCtx, namespaces, apps, accounts string) {
	t.Helper()
	runner.On("kubectl", nsArgs(kubeCtx), exec.Result{Stdout: []byte(namespaces)})
	runner.On("kubectl", appsArgs(kubeCtx), exec.Result{Stdout: []byte(apps)})
	runner.On("kubectl", saArgs(kubeCtx), exec.Result{Stdout: []byte(accounts)})
}

// assertContextCalls fails when a kubectl call of the plan does not select
// kubeCtx; config calls select no context and are skipped.
func assertContextCalls(t *testing.T, runner *fake.Runner, kubeCtx string) {
	t.Helper()
	for _, c := range runner.Calls() {
		if c.Name != "kubectl" {
			continue
		}
		if len(c.Args) > 0 && c.Args[0] == "config" {
			continue
		}
		if len(c.Args) < 2 || c.Args[0] != "--context" || c.Args[1] != kubeCtx {
			t.Fatalf("kubectl call without --context %s: %v", kubeCtx, c.Args)
		}
	}
}

// assertNoDelete fails when the plan ran a kubectl delete.
func assertNoDelete(t *testing.T, runner *fake.Runner) {
	t.Helper()
	for _, c := range runner.Calls() {
		if c.Name != "kubectl" {
			continue
		}
		for _, a := range c.Args {
			if a == "delete" {
				t.Fatalf("delete called: %v", c.Args)
			}
		}
	}
}
