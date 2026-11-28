package kube

import (
	"context"
	"testing"

	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
)

// contextSetFixture programs the kubeconfig queries of DevzoneContextSet for
// the cluster context name, and the set-context call that must follow it with
// contextName as the name of the created context.
func contextSetFixture(t *testing.T, cluster, contextName string) *fake.Runner {
	t.Helper()
	runner := fake.New()
	runner.On("kubectl", []string{"config", "view", "-o",
		`{.contexts[?(@.name=="` + cluster + `")].context.cluster}`},
		fexec.Result{Stdout: []byte(cluster + "-cluster\n")})
	runner.On("kubectl", []string{"config", "view", "-o",
		`{.contexts[?(@.name=="` + cluster + `")].context.user}`},
		fexec.Result{Stdout: []byte(cluster + "-user\n")})
	runner.On("kubectl", []string{"config", "set-context", contextName,
		"--cluster=" + cluster + "-cluster", "--user=" + cluster + "-user"}, fexec.Result{})
	return runner
}

// assertSetContextName fails unless one set-context call created want.
func assertSetContextName(t *testing.T, runner *fake.Runner, want string) {
	t.Helper()
	for _, c := range runner.Calls() {
		if c.Name == "kubectl" && len(c.Args) >= 3 && c.Args[0] == "config" && c.Args[1] == "set-context" {
			if c.Args[2] != want {
				t.Fatalf("set-context = %q, want %q", c.Args[2], want)
			}
			return
		}
	}
	t.Fatal("set-context never called")
}

// TestDevzoneContextSetDefaultName: without DEVZONE_CONTEXT the created
// context carries the default services name.
func TestDevzoneContextSetDefaultName(t *testing.T) {
	t.Setenv("DEVZONE_CONTEXT", "")
	runner := contextSetFixture(t, "kind-devzone", "devzone")
	k := Kube{Runner: runner}
	if !k.DevzoneContextSet(context.Background(), "kind-devzone") {
		t.Fatal("DevzoneContextSet = false, want true")
	}
	assertSetContextName(t, runner, "devzone")
}

// TestDevzoneContextSetOverriddenName: DEVZONE_CONTEXT names the context that
// set-context creates, never the default literal.
func TestDevzoneContextSetOverriddenName(t *testing.T) {
	t.Setenv("DEVZONE_CONTEXT", "autre")
	runner := contextSetFixture(t, "kind-devzone", "autre")
	k := Kube{Runner: runner}
	if !k.DevzoneContextSet(context.Background(), "kind-devzone") {
		t.Fatal("DevzoneContextSet = false, want true")
	}
	assertSetContextName(t, runner, "autre")
}
