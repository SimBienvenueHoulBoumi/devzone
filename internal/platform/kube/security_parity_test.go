package kube

import (
	"context"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/testkit"
)

// accountSetup creates a disposable kubeconfig and the neutral fake answers of
// the administrator calls, so every argument can be frozen without a cluster.
func accountSetup(t *testing.T) (*Kube, *fake.Runner, string) {
	t.Helper()
	home := testkit.TempHome(t)
	conf := filepath.Join(home, ".kube", "config")
	if err := os.MkdirAll(filepath.Dir(conf), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(conf, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("DEVZONE_KUBE_HOST", filepath.Join(home, ".kube", "hote.config"))
	t.Setenv("DEVZONE_KUBE_CONFIG", conf)
	r := fake.New()
	r.On("kubectl", nil, exec.Result{})
	return &Kube{Runner: r}, r, conf
}

// TestAdminCallKeepsExplicitKubeconfig freezes the administrator call of
// account_admin: one explicit kubeconfig holding the context, never the
// combined KUBECONFIG of the shell.
func TestAdminCallKeepsExplicitKubeconfig(t *testing.T) {
	k, r, conf := accountSetup(t)
	if _, err := k.AccountAdmin(context.Background(), "host-context", "get", "nodes"); err != nil {
		t.Fatal(err)
	}
	calls := r.Calls()
	if len(calls) != 1 {
		t.Fatalf("calls = %+v", calls)
	}
	want := []string{"--kubeconfig=" + conf, "--context", "host-context", "get", "nodes"}
	if strings.Join(calls[0].Args, "\x00") != strings.Join(want, "\x00") {
		t.Fatalf("args = %q, want %q", calls[0].Args, want)
	}
	if len(calls[0].Opts.Env) != 0 {
		t.Fatalf("admin call must not inherit a combined KUBECONFIG: %+v", calls[0].Opts.Env)
	}
}

// TestAccountAllowFreezesRoleBinding freezes the RoleBinding and ServiceAccount
// creation of account_allow and the namespaces they are applied in.
func TestAccountAllowFreezesRoleBinding(t *testing.T) {
	k, r, conf := accountSetup(t)
	if err := k.AccountAllow(context.Background(), "host-context", "devzone-postgres", nil); err != nil {
		t.Fatal(err)
	}
	prefix := []string{"--kubeconfig=" + conf, "--context", "host-context"}
	want := [][]string{
		{"create", "namespace", "devzone-system", "--dry-run=client", "-o", "yaml"},
		{"apply", "-f", "-"},
		{"-n", "devzone-system", "create", "serviceaccount", "devzone-agent", "--dry-run=client", "-o", "yaml"},
		{"apply", "-f", "-"},
		{"-n", "devzone-postgres", "create", "rolebinding", "devzone-agent", "--clusterrole=edit", "--serviceaccount=devzone-system:devzone-agent", "--dry-run=client", "-o", "yaml"},
		{"apply", "-f", "-"},
	}
	calls := r.Calls()
	if len(calls) != len(want) {
		t.Fatalf("calls = %d, want %d", len(calls), len(want))
	}
	for i, args := range want {
		full := append(append([]string{}, prefix...), args...)
		if strings.Join(calls[i].Args, "\x00") != strings.Join(full, "\x00") {
			t.Fatalf("call %d = %q, want %q", i, calls[i].Args, full)
		}
	}
}

// TestNamespaceIsolateFreezesPolicy freezes the manifest of isolation.sh sent
// on standard input by namespace_isolate.
func TestNamespaceIsolateFreezesPolicy(t *testing.T) {
	k, r, _ := accountSetup(t)
	if err := k.NamespaceIsolate(context.Background(), "devzone-postgres", nil); err != nil {
		t.Fatal(err)
	}
	calls := r.Calls()
	if len(calls) != 1 {
		t.Fatalf("calls = %+v", calls)
	}
	wantArgs := []string{"--context", "devzone", "-n", "devzone-postgres", "apply", "-f", "-"}
	if strings.Join(calls[0].Args, "\x00") != strings.Join(wantArgs, "\x00") {
		t.Fatalf("args = %q", calls[0].Args)
	}
	manifest := stdinText(t, calls[0].Opts.Stdin)
	for _, line := range []string{"apiVersion: networking.k8s.io/v1", "kind: NetworkPolicy",
		"name: devzone-meme-namespace", "app.kubernetes.io/managed-by: devzone",
		"podSelector: {}", "- podSelector: {}"} {
		if !strings.Contains(manifest, line) {
			t.Fatalf("manifest misses %q: %q", line, manifest)
		}
	}
}

// stdinText reads all of a command's standard input for a manifest assertion.
func stdinText(t *testing.T, reader io.Reader) string {
	t.Helper()
	data, err := io.ReadAll(reader)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

// TestMetricsCallsNeverUseAdminContext freezes the metrics calls: they run on
// the requested context, never with the administrator kubeconfig.
func TestMetricsCallsNeverUseAdminContext(t *testing.T) {
	k, r, _ := accountSetup(t)
	r.On("kubectl", []string{"config", "get-contexts", "-o", "name"}, exec.Result{Stdout: []byte("host-context\n")})
	code := k.Metrics(context.Background(), []string{"retirer", "host-context"}, nil, nil)
	if code != 0 {
		t.Fatalf("code = %d", code)
	}
}
