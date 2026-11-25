package podcmd

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/testkit"
)

// accountFixture writes a chosen services cluster in a temporary state folder.
func accountFixture(t *testing.T, contextName string) string {
	t.Helper()
	home := testkit.TempHome(t)
	if err := os.MkdirAll(filepath.Join(home, ".kube"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("DEVZONE_KUBE_CONFIG", filepath.Join(home, ".kube", "config"))
	t.Setenv("DEVZONE_KUBE_AGENT_CONFIG", filepath.Join(home, ".kube", "agent.config"))
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, ".devzone.modules"),
		[]byte("kubernetes=on\ncluster="+contextName+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("DEVZONE_ROOT", root)
	t.Setenv("DEVZONE_STATE", "")
	return root
}

// programAccountToken programs the whole renewal: setup, catch-up, TokenRequest,
// context writes, auth check and reduced agent kubeconfig.
func programAccountToken(r *fake.Runner, contextName string) {
	admin := func(args ...string) []string {
		return append([]string{"--context", contextName}, args...)
	}
	r.On("kubectl", admin("create", "namespace", "devzone-system", "--dry-run=client", "-o", "yaml"), exec.Result{
		Stdout: []byte("kind: Namespace\n"),
	})
	r.On("kubectl", admin("apply", "-f", "-"), exec.Result{})
	r.On("kubectl", admin("-n", "devzone-system", "create", "serviceaccount", "devzone-agent",
		"--dry-run=client", "-o", "yaml"), exec.Result{Stdout: []byte("kind: ServiceAccount\n")})
	r.On("kubectl", admin("get", "namespaces", "-l", "app.kubernetes.io/managed-by=devzone",
		"-o", "name"), exec.Result{})
	r.On("kubectl", admin("create", "token", "devzone-agent", "-n", "devzone-system", "--duration=24h",
		"-o", `jsonpath={.status.token}{"\n"}{.status.expirationTimestamp}`), exec.Result{
		Stdout: []byte("token-test\n2030-01-01T00:00:00Z\n"),
	})
	r.On("kubectl", []string{"config", "view", "-o",
		`{.contexts[?(@.name=="` + contextName + `")].context.cluster}`}, exec.Result{
		Stdout: []byte(contextName + "\n"),
	})
	r.On("kubectl", []string{"config", "view", "-o",
		`{.clusters[?(@.name=="` + contextName + `")].cluster.server}`}, exec.Result{
		Stdout: []byte("https://127.0.0.1:6443\n"),
	})
	r.On("kubectl", []string{"config", "view", "--raw", "-o",
		`{.clusters[?(@.name=="` + contextName + `")].cluster.certificate-authority-data}`}, exec.Result{})
	r.On("kubectl", []string{"config", "view", "-o",
		`{.clusters[?(@.name=="` + contextName + `")].cluster.certificate-authority}`}, exec.Result{})
	r.On("kubectl", []string{"config", "view", "-o",
		`{.clusters[?(@.name=="` + contextName + `")].cluster.tls-server-name}`}, exec.Result{})
	r.On("kubectl", []string{"config", "set-cluster", contextName, "--server=https://127.0.0.1:6443"}, exec.Result{})
	r.On("kubectl", []string{"config", "set-credentials", "devzone-agent", "--token", "token-test"}, exec.Result{})
	r.On("kubectl", []string{"config", "set-context", "devzone", "--cluster", contextName,
		"--user", "devzone-agent"}, exec.Result{})
	r.On("kubectl", []string{"--context", "devzone", "auth", "can-i", "get", "pods",
		"-n", "devzone-system"}, exec.Result{Stdout: []byte("yes\n")})
	r.On("kubectl", []string{"config", "view", "--minify", "--flatten", "--context", "devzone"}, exec.Result{
		Stdout: []byte("apiVersion: v1\n"),
	})
	r.On("kubectl", []string{"config", "use-context", "devzone"}, exec.Result{})
}

// runAccountArgs runs an account command with a fake runner and captured
// outputs.
func runAccountArgs(args []string, r *fake.Runner) (int, string, string) {
	var out, errOut strings.Builder
	ctx := &cli.Context{Args: args, Out: &out, Err: &errOut, Runner: r}
	return runAccount(ctx), out.String(), errOut.String()
}

// TestAccountTokenWithoutCluster checks that no kubectl call is made without a
// chosen services cluster.
func TestAccountTokenWithoutCluster(t *testing.T) {
	root := t.TempDir()
	t.Setenv("DEVZONE_ROOT", root)
	t.Setenv("DEVZONE_STATE", filepath.Join(root, "modules"))
	if err := os.WriteFile(filepath.Join(root, "modules"), []byte("kubernetes=on\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	r := testkit.FakeRunner(t)
	code, out, errOut := runAccountArgs([]string{"token"}, r)
	if code != 0 || out != "" || errOut != "" {
		t.Fatalf("account token = %d, %q, %q; want 0 and no output", code, out, errOut)
	}
	if len(r.Calls()) != 0 {
		t.Fatalf("calls = %+v, want none", r.Calls())
	}
}

// TestAccountTokenRenews checks the complete cycle from the state and the
// reduced agent kubeconfig written after the token.
func TestAccountTokenRenews(t *testing.T) {
	accountFixture(t, "kind-devzone")
	r := testkit.FakeRunner(t)
	programAccountToken(r, "kind-devzone")
	code, out, errOut := runAccountArgs([]string{"token"}, r)
	if code != 0 || out != "" || errOut != "" {
		t.Fatalf("account token = %d, %q, %q; want 0 and no output", code, out, errOut)
	}
	calls := r.Calls()
	if len(calls) == 0 {
		t.Fatal("no kubectl call: the token was not renewed")
	}
	last := calls[len(calls)-1]
	if got := strings.Join(last.Args, " "); got != "config use-context devzone" {
		t.Fatalf("last call = %q, want the agent context after the token", got)
	}
}

// TestAccountFresh checks that the freshness command prints nothing and only
// reports the state of the expiry file through its exit code.
func TestAccountFresh(t *testing.T) {
	path := filepath.Join(t.TempDir(), "devzone-token.expiry")
	t.Setenv("DEVZONE_KUBE_TOKEN_EXPIRY", path)
	r := testkit.FakeRunner(t)
	if err := os.WriteFile(path, []byte("10"), 0o600); err != nil {
		t.Fatal(err)
	}
	code, out, errOut := runAccountArgs([]string{"fresh"}, r)
	if code != 1 || out != "" || errOut != "" {
		t.Fatalf("account fresh = %d, %q, %q; want 1 and no output", code, out, errOut)
	}
	if err := os.WriteFile(path, []byte("9999999999"), 0o600); err != nil {
		t.Fatal(err)
	}
	code, out, errOut = runAccountArgs([]string{"fresh"}, r)
	if code != 0 || out != "" || errOut != "" {
		t.Fatalf("account fresh = %d, %q, %q; want 0 and no output", code, out, errOut)
	}
	if len(r.Calls()) != 0 {
		t.Fatalf("account fresh made network calls: %+v", r.Calls())
	}
}

// TestAccountUsage checks the usage message and the exit code of an unknown
// account command.
func TestAccountUsage(t *testing.T) {
	r := testkit.FakeRunner(t)
	code, out, errOut := runAccountArgs([]string{"nope"}, r)
	if code != 2 || out != "" || !strings.Contains(errOut, "usage: devzone account token") {
		t.Fatalf("account nope = %d, %q, %q; want the usage and code 2", code, out, errOut)
	}
	if len(r.Calls()) != 0 {
		t.Fatalf("calls = %+v, want none", r.Calls())
	}
}
