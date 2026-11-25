package kube

import (
	"context"
	"path/filepath"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/testkit"
)

// setupFixture isolates the home and the kubeconfigs of the account library
// tests, and installs the fake runner.
func setupFixture(t *testing.T) (*fake.Runner, string) {
	t.Helper()
	home := testkit.TempHome(t)
	conf := filepath.Join(home, ".kube", "config")
	t.Setenv("DEVZONE_KUBE_HOST", filepath.Join(home, ".kube", "hote.config"))
	t.Setenv("DEVZONE_KUBE_CONFIG", conf)
	return withRunner(t), conf
}

// adminArgs prepends the explicit administrator context of account_admin.
func adminArgs(contextName string, args ...string) []string {
	return append([]string{"--context", contextName}, args...)
}

// programCreateApply programs the create | apply -f - pipeline of the shell
// library, including the administrator context of every kubectl call.
func programCreateApply(r *fake.Runner, contextName string, create []string, kind string) {
	r.On("kubectl", adminArgs(contextName, create...), exec.Result{Stdout: []byte("kind: " + kind + "\n")})
	r.On("kubectl", adminArgs(contextName, "apply", "-f", "-"), exec.Result{})
}

// assertAdminCalls checks the explicit context and the kubeconfig of every
// administrator call.
func assertAdminCalls(t *testing.T, calls []fake.Call, conf string) {
	t.Helper()
	for _, call := range calls {
		if len(call.Args) < 2 || call.Args[0] != "--context" {
			t.Fatalf("call without the administrator context: %+v", call)
		}
		if len(call.Opts.Env) != 1 || call.Opts.Env[0] != "KUBECONFIG="+conf {
			t.Fatalf("call with the wrong kubeconfig: %+v", call)
		}
	}
}

// inputOf returns the YAML piped into an apply -f - call.
func inputOf(t *testing.T, call fake.Call) string {
	t.Helper()
	if call.Opts.Stdin == nil {
		return ""
	}
	var out strings.Builder
	buf := make([]byte, 512)
	for {
		n, err := call.Opts.Stdin.Read(buf)
		out.Write(buf[:n])
		if err != nil {
			return out.String()
		}
	}
}

// TestSetupCreatesTheNamespaceAndServiceAccount checks that the limited
// account is set up with the administrator context, and that the YAML created
// by kubectl is really piped into apply.
func TestSetupCreatesTheNamespaceAndServiceAccount(t *testing.T) {
	r, conf := setupFixture(t)
	namespace := []string{"create", "namespace", "devzone-system", "--dry-run=client", "-o", "yaml"}
	serviceAccount := []string{"-n", "devzone-system", "create", "serviceaccount", "devzone-agent",
		"--dry-run=client", "-o", "yaml"}
	programCreateApply(r, "docker-desktop", namespace, "Namespace")
	programCreateApply(r, "docker-desktop", serviceAccount, "ServiceAccount")
	if err := (Kube{Runner: r}).Setup(context.Background(), "docker-desktop"); err != nil {
		t.Fatal(err)
	}
	calls := r.Calls()
	if len(calls) != 4 {
		t.Fatalf("calls = %d, want 4: %+v", len(calls), calls)
	}
	assertAdminCalls(t, calls, conf)
	if got := strings.Join(calls[0].Args, " "); got != strings.Join(adminArgs("docker-desktop", namespace...), " ") {
		t.Fatalf("first call = %q", got)
	}
	if got := strings.Join(calls[2].Args, " "); got != strings.Join(adminArgs("docker-desktop", serviceAccount...), " ") {
		t.Fatalf("third call = %q", got)
	}
	if !strings.Contains(inputOf(t, calls[1]), "kind: Namespace") {
		t.Fatalf("namespace apply input = %q", inputOf(t, calls[1]))
	}
	if !strings.Contains(inputOf(t, calls[3]), "kind: ServiceAccount") {
		t.Fatalf("serviceaccount apply input = %q", inputOf(t, calls[3]))
	}
}

// TestSetupFailingKubectlFails checks the setup when the administrator cannot
// create the namespace or cannot apply it.
func TestSetupFailingKubectlFails(t *testing.T) {
	for _, applyFails := range []bool{false, true} {
		r, _ := setupFixture(t)
		r.On("kubectl", adminArgs("docker-desktop", "create", "namespace", "devzone-system",
			"--dry-run=client", "-o", "yaml"), exec.Result{Stdout: []byte("kind: Namespace\n"), Code: 0})
		if applyFails {
			r.On("kubectl", adminArgs("docker-desktop", "apply", "-f", "-"), exec.Result{Code: 1})
		} else {
			r.On("kubectl", adminArgs("docker-desktop", "create", "namespace", "devzone-system",
				"--dry-run=client", "-o", "yaml"), exec.Result{Code: 1})
		}
		if err := (Kube{Runner: r}).Setup(context.Background(), "docker-desktop"); err == nil {
			t.Fatalf("Setup with applyFails=%v = nil, want an error", applyFails)
		}
	}
}

// TestAllowSetsTheRoleBindingAfterSetup checks that the limited account is
// created before the RoleBinding to the edit ClusterRole.
func TestAllowSetsTheRoleBindingAfterSetup(t *testing.T) {
	r, conf := setupFixture(t)
	programCreateApply(r, "docker-desktop", []string{"create", "namespace", "devzone-system",
		"--dry-run=client", "-o", "yaml"}, "Namespace")
	programCreateApply(r, "docker-desktop", []string{"-n", "devzone-system", "create",
		"serviceaccount", "devzone-agent", "--dry-run=client", "-o", "yaml"}, "ServiceAccount")
	rolebinding := []string{"-n", "devzone-postgres", "create", "rolebinding", "devzone-agent",
		"--clusterrole=edit", "--serviceaccount=devzone-system:devzone-agent", "--dry-run=client", "-o", "yaml"}
	programCreateApply(r, "docker-desktop", rolebinding, "RoleBinding")
	if err := (Kube{Runner: r}).Allow(context.Background(), "docker-desktop", "devzone-postgres"); err != nil {
		t.Fatal(err)
	}
	calls := r.Calls()
	if len(calls) != 6 {
		t.Fatalf("calls = %d, want 6: %+v", len(calls), calls)
	}
	assertAdminCalls(t, calls, conf)
	if got := strings.Join(calls[4].Args, " "); got != strings.Join(adminArgs("docker-desktop", rolebinding...), " ") {
		t.Fatalf("rolebinding call = %q", got)
	}
	if !strings.Contains(inputOf(t, calls[5]), "kind: RoleBinding") {
		t.Fatalf("rolebinding apply input = %q", inputOf(t, calls[5]))
	}
}

// TestCatchUpIsIdempotent checks that each labelled namespace gets one
// RoleBinding, and that a second pass does not add another one.
func TestCatchUpIsIdempotent(t *testing.T) {
	r, _ := setupFixture(t)
	r.On("kubectl", adminArgs("docker-desktop", "get", "namespaces", "-l",
		"app.kubernetes.io/managed-by=devzone", "-o", "name"), exec.Result{
		Stdout: []byte("namespace/devzone-mysql\nnamespace/devzone-gitlab\n"),
	})
	for _, ns := range []string{"devzone-mysql", "devzone-gitlab"} {
		programCreateApply(r, "docker-desktop", []string{"-n", ns, "create", "rolebinding", "devzone-agent",
			"--clusterrole=edit", "--serviceaccount=devzone-system:devzone-agent",
			"--dry-run=client", "-o", "yaml"}, "RoleBinding")
	}
	api := Kube{Runner: r}
	for pass := 0; pass < 2; pass++ {
		if err := api.CatchUp(context.Background(), "docker-desktop"); err != nil {
			t.Fatal(err)
		}
	}
	rolebindings, applies := 0, 0
	for _, call := range r.Calls() {
		if strings.Contains(strings.Join(call.Args, " "), "create rolebinding") {
			rolebindings++
		}
		if strings.Contains(strings.Join(call.Args, " "), "apply -f -") {
			applies++
		}
	}
	if rolebindings != 4 || applies != 4 {
		t.Fatalf("rolebindings = %d, applies = %d; want 4 each", rolebindings, applies)
	}
}

// TestCatchUpIgnoresUnreadableNamespaces checks that a failed namespace listing
// is not an error, as in the shell original.
func TestCatchUpIgnoresUnreadableNamespaces(t *testing.T) {
	r, _ := setupFixture(t)
	r.On("kubectl", adminArgs("docker-desktop", "get", "namespaces", "-l",
		"app.kubernetes.io/managed-by=devzone", "-o", "name"), exec.Result{Code: 1})
	if err := (Kube{Runner: r}).CatchUp(context.Background(), "docker-desktop"); err != nil {
		t.Fatalf("CatchUp = %v, want nil", err)
	}
	if len(r.Calls()) != 1 {
		t.Fatalf("calls = %+v, want only the namespace listing", r.Calls())
	}
}
