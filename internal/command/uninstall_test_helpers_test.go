package command

import (
	"errors"
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
	// Not in the pod, and no kubectl on the host: the tests never read the host
	t.Setenv("DEVZONE_IN_CONTAINER", "no")
	t.Setenv("DEVZONE_DOCKER", "")
	t.Setenv("DEVZONE_COMMAND", "")
	t.Setenv("KEEP", "")
	t.Setenv("GARDER", "")
	t.Setenv("CONFIRM", "")
	t.Setenv("CONFIRMER", "")
	previous, previousExists := commandPortsDisable, commandPortsAutoStartExists
	previousLook := lookPath
	commandPortsDisable = func(io.Writer, io.Writer) int { return 0 }
	commandPortsAutoStartExists = func() bool { return true }
	lookPath = func(string) (string, error) { return "", errNoKubectlTest }
	t.Cleanup(func() {
		commandPortsDisable, commandPortsAutoStartExists = previous, previousExists
		lookPath = previousLook
	})
	return root
}

// errNoKubectlTest is the lookup failure of a host without kubectl.
var errNoKubectlTest = errors.New("kubectl not found (test)")

// registerHostProbe answers the host calls of an uninstall that finds nothing on
// the host: the engine info succeeds, and the devcontainer configuration has no
// mount. Every other engine call of the inventory fails, which counts as none.
func registerHostProbe(t *testing.T, runner *fake.Runner, root string) {
	t.Helper()
	runner.On(engineCommand(), []string{"info"}, exec.Result{})
	paths := []string{root}
	if phys, err := filepath.EvalSymlinks(root); err == nil && phys != root {
		paths = append(paths, phys)
	}
	for _, p := range paths {
		runner.On("npx", []string{"-y", "@devcontainers/cli", "read-configuration", "--workspace-folder", p},
			exec.Result{Stdout: []byte(`{"configuration":{"mounts":[]}}`)})
	}
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
