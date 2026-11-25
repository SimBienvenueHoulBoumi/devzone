package podcmd

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/testkit"
)

// TestAccountTokenUsesStateFile checks that DEVZONE_STATE is read as the state
// file itself, and that the last chosen services cluster wins.
func TestAccountTokenUsesStateFile(t *testing.T) {
	home := testkit.TempHome(t)
	if err := os.MkdirAll(filepath.Join(home, ".kube"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("DEVZONE_KUBE_CONFIG", filepath.Join(home, ".kube", "config"))
	t.Setenv("DEVZONE_KUBE_AGENT_CONFIG", filepath.Join(home, ".kube", "agent.config"))
	root := t.TempDir()
	stateFile := filepath.Join(root, "modules")
	if err := os.WriteFile(stateFile, []byte("cluster=kind-old\ncluster=docker-desktop\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("DEVZONE_STATE", stateFile)
	r := testkit.FakeRunner(t)
	programAccountToken(r, "docker-desktop")
	code, _, errOut := runAccountArgs([]string{"token"}, r)
	if code != 0 || errOut != "" {
		t.Fatalf("account token = %d, %q; want 0 and no output", code, errOut)
	}
	for _, call := range r.Calls() {
		if strings.Contains(strings.Join(call.Args, " "), "kind-old") {
			t.Fatalf("old cluster still chosen: %+v", call)
		}
	}
	if !strings.Contains(strings.Join(r.Calls()[0].Args, " "), "--context docker-desktop create namespace") {
		t.Fatalf("first call = %+v, want the chosen cluster", r.Calls()[0])
	}
}

// TestAccountTokenCatchesUpNamespaces checks that the existing labelled
// namespaces get one RoleBinding each, also on a second identical renewal.
func TestAccountTokenCatchesUpNamespaces(t *testing.T) {
	accountFixture(t, "docker-desktop")
	r := testkit.FakeRunner(t)
	programAccountToken(r, "docker-desktop")
	r.On("kubectl", []string{"--context", "docker-desktop", "get", "namespaces", "-l",
		"app.kubernetes.io/managed-by=devzone", "-o", "name"}, exec.Result{
		Stdout: []byte("namespace/devzone-mysql\nnamespace/devzone-gitlab\n"),
	})
	for _, ns := range []string{"devzone-mysql", "devzone-gitlab"} {
		r.On("kubectl", []string{"--context", "docker-desktop", "-n", ns, "create", "rolebinding",
			"devzone-agent", "--clusterrole=edit", "--serviceaccount=devzone-system:devzone-agent",
			"--dry-run=client", "-o", "yaml"}, exec.Result{Stdout: []byte("kind: RoleBinding\n")})
	}
	for pass := 0; pass < 2; pass++ {
		code, _, errOut := runAccountArgs([]string{"token"}, r)
		if code != 0 || errOut != "" {
			t.Fatalf("account token = %d, %q; want 0 and no output", code, errOut)
		}
	}
	for _, ns := range []string{"devzone-mysql", "devzone-gitlab"} {
		count := 0
		for _, call := range r.Calls() {
			if strings.Contains(strings.Join(call.Args, " "), "-n "+ns+" create rolebinding") {
				count++
			}
		}
		if count != 2 {
			t.Fatalf("RoleBinding of %s written %d times, want 2 (one per renewal)", ns, count)
		}
	}
}

// TestAccountTokenReportsUnreachableContext checks the message of the shell
// original when the devzone context does not answer the auth check.
func TestAccountTokenReportsUnreachableContext(t *testing.T) {
	accountFixture(t, "docker-desktop")
	r := testkit.FakeRunner(t)
	programAccountToken(r, "docker-desktop")
	r.On("kubectl", []string{"--context", "devzone", "auth", "can-i", "get", "pods",
		"-n", "devzone-system"}, exec.Result{Stdout: []byte("Error from server (Unauthorized)\n"), Code: 1})
	code, _, errOut := runAccountArgs([]string{"token"}, r)
	if code != 1 || errOut != "devzone : limited account context not reachable\n" {
		t.Fatalf("account token = %d, %q; want the shell message and code 1", code, errOut)
	}
}

// TestAccountTokenFailureIsReported checks that any failure of the renewal is
// written on stderr: a token that is not renewed is never silent (in the
// shell, kubectl wrote its own error).
func TestAccountTokenFailureIsReported(t *testing.T) {
	accountFixture(t, "docker-desktop")
	r := testkit.FakeRunner(t)
	programAccountToken(r, "docker-desktop")
	r.On("kubectl", []string{"--context", "docker-desktop", "create", "namespace", "devzone-system",
		"--dry-run=client", "-o", "yaml"}, exec.Result{Code: 1})
	code, out, errOut := runAccountArgs([]string{"token"}, r)
	if code != 1 || out != "" {
		t.Fatalf("account token = %d, %q; want 1 and nothing on stdout", code, out)
	}
	if !strings.Contains(errOut, "devzone : limited account token not renewed:") {
		t.Fatalf("stderr = %q, want the failure reported", errOut)
	}
}

// TestAccountTokenEmptyTokenMessage checks the message of an empty
// TokenRequest response.
func TestAccountTokenEmptyTokenMessage(t *testing.T) {
	accountFixture(t, "docker-desktop")
	r := testkit.FakeRunner(t)
	programAccountToken(r, "docker-desktop")
	r.On("kubectl", []string{"--context", "docker-desktop", "create", "token", "devzone-agent",
		"-n", "devzone-system", "--duration=24h",
		"-o", `jsonpath={.status.token}{"\n"}{.status.expirationTimestamp}`}, exec.Result{
		Stdout: []byte("\n2030-01-01T00:00:00Z\n"),
	})
	code, _, errOut := runAccountArgs([]string{"token"}, r)
	if code != 1 || errOut != "devzone : limited account token is empty\n" {
		t.Fatalf("account token = %d, %q; want the shell message and code 1", code, errOut)
	}
}
