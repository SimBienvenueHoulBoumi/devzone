package kube

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/testkit"
)

// tokenFixture isolates the home, the kubeconfigs and the expiry file of the
// token tests, and installs the fake runner.
func tokenFixture(t *testing.T) (string, string, string, *fake.Runner) {
	t.Helper()
	home := testkit.TempHome(t)
	if err := os.MkdirAll(filepath.Join(home, ".kube"), 0o755); err != nil {
		t.Fatal(err)
	}
	conf := filepath.Join(home, ".kube", "config")
	t.Setenv("DEVZONE_KUBE_HOST", filepath.Join(home, ".kube", "hote.config"))
	t.Setenv("DEVZONE_KUBE_CONFIG", conf)
	expiry := filepath.Join(home, ".kube", "devzone-token.expiry")
	t.Setenv("DEVZONE_KUBE_TOKEN_EXPIRY", expiry)
	return home, conf, expiry, withRunner(t)
}

// programTokenRequest programs the TokenRequest of the limited account on the
// administrator context.
func programTokenRequest(r *fake.Runner, contextName string, out []byte) {
	r.On("kubectl", adminArgs(contextName, "create", "token", "devzone-agent", "-n", "devzone-system",
		"--duration=24h", "-o", tokenJSONPath), exec.Result{Stdout: out})
}

// programTokenReads programs the four kubeconfig reads of the token cycle: the
// cluster of the administrator context, its server, its certificate authority
// (read with --raw) and its TLS server name.
func programTokenReads(r *fake.Runner, contextName, cluster, server, caData, caFile, tls string) {
	r.On("kubectl", []string{"config", "view", "-o",
		`jsonpath={.contexts[?(@.name=="` + contextName + `")].context.cluster}`}, exec.Result{
		Stdout: []byte(cluster + "\n"),
	})
	r.On("kubectl", []string{"config", "view", "-o",
		`jsonpath={.clusters[?(@.name=="` + cluster + `")].cluster.server}`}, exec.Result{
		Stdout: []byte(server + "\n"),
	})
	r.On("kubectl", []string{"config", "view", "--raw", "-o",
		`jsonpath={.clusters[?(@.name=="` + cluster + `")].cluster.certificate-authority-data}`}, exec.Result{
		Stdout: []byte(caData),
	})
	r.On("kubectl", []string{"config", "view", "-o",
		`jsonpath={.clusters[?(@.name=="` + cluster + `")].cluster.certificate-authority}`}, exec.Result{
		Stdout: []byte(caFile),
	})
	r.On("kubectl", []string{"config", "view", "-o",
		`jsonpath={.clusters[?(@.name=="` + cluster + `")].cluster.tls-server-name}`}, exec.Result{
		Stdout: []byte(tls),
	})
}

// programTokenWrites programs a successful write of the context, credentials
// and auth check; the certificate authority data is written after set-cluster.
func programTokenWrites(r *fake.Runner, cluster, token, caData string) {
	r.On("kubectl", []string{"config", "set-cluster", cluster, "--server=https://127.0.0.1:6443"}, exec.Result{})
	if caData != "" {
		r.On("kubectl", []string{"config", "set", "clusters." + cluster + ".certificate-authority-data", caData}, exec.Result{})
	}
	r.On("kubectl", []string{"config", "set-credentials", "devzone-agent", "--token", token}, exec.Result{})
	r.On("kubectl", []string{"config", "set-context", "devzone", "--cluster", cluster, "--user", "devzone-agent"}, exec.Result{})
	programTokenAuth(r, "yes\n", 0)
}

// programTokenAuth programs the auth can-i answer through the devzone context.
func programTokenAuth(r *fake.Runner, answer string, code int) {
	r.On("kubectl", []string{"--context", "devzone", "auth", "can-i", "get", "pods",
		"-n", "devzone-system"}, exec.Result{Stdout: []byte(answer), Code: code})
}

// assertKubeconfig checks that every kubectl call carries the right KUBECONFIG
// in its options.
func assertKubeconfig(t *testing.T, calls []fake.Call, conf string) {
	t.Helper()
	for _, call := range calls {
		if len(call.Opts.Env) != 1 || call.Opts.Env[0] != "KUBECONFIG="+conf {
			t.Fatalf("call with the wrong kubeconfig: %+v", call)
		}
	}
}

// TestTokenRenewsAndWritesContext checks the 24 h TokenRequest, the certificate
// authority written by config set after set-cluster, the auth check and the
// expiry file written with mode 600.
func TestTokenRenewsAndWritesContext(t *testing.T) {
	_, conf, expiry, r := tokenFixture(t)
	programTokenRequest(r, "docker-desktop", []byte("token-test\n2030-01-01T00:00:00Z\n"))
	programTokenReads(r, "docker-desktop", "cluster-hote", "https://127.0.0.1:6443",
		"Y2EtdGVzdAo=", "", "")
	programTokenWrites(r, "cluster-hote", "token-test", "Y2EtdGVzdAo=")
	if err := (Kube{Runner: r}).Token(context.Background(), "docker-desktop"); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(expiry)
	if err != nil {
		t.Fatal(err)
	}
	if got := string(data); got != "1893456000\n" {
		t.Fatalf("expiry = %q, want %q", got, "1893456000\n")
	}
	if info, err := os.Stat(expiry); err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("expiry mode = %v, %v; want 600", info, err)
	}
	calls := r.Calls()
	if len(calls) != 11 {
		t.Fatalf("calls = %d, want 11: %+v", len(calls), calls)
	}
	assertKubeconfig(t, calls, conf)
	if got := strings.Join(calls[0].Args, " "); !strings.HasPrefix(got, "--context docker-desktop create token") {
		t.Fatalf("TokenRequest call = %q", got)
	}
	args := strings.Join(calls[6].Args, " ")
	if !strings.HasPrefix(args, "config set-cluster cluster-hote --server=") || strings.Contains(args, "certificate-authority-data") {
		t.Fatalf("set-cluster call = %q", args)
	}
	if got := strings.Join(calls[7].Args, " "); got != "config set clusters.cluster-hote.certificate-authority-data Y2EtdGVzdAo=" {
		t.Fatalf("certificate authority call = %q", got)
	}
	if got := strings.Join(calls[10].Args, " "); got != "--context devzone auth can-i get pods -n devzone-system" {
		t.Fatalf("auth call = %q", got)
	}
}

// TestTokenWithCertificateAuthorityFile checks that the file form of the
// certificate authority stays in set-cluster with --embed-certs, while the
// data form is still written by config set.
func TestTokenWithCertificateAuthorityFile(t *testing.T) {
	_, _, _, r := tokenFixture(t)
	programTokenRequest(r, "docker-desktop", []byte("token-test\n2030-01-01T00:00:00Z\n"))
	programTokenReads(r, "docker-desktop", "cluster-hote", "https://127.0.0.1:6443",
		"", "/tmp/account-ca.crt", "hote.internal")
	r.On("kubectl", []string{"config", "set-cluster", "cluster-hote", "--server=https://127.0.0.1:6443",
		"--certificate-authority=/tmp/account-ca.crt", "--embed-certs=true",
		"--tls-server-name=hote.internal"}, exec.Result{})
	r.On("kubectl", []string{"config", "set-credentials", "devzone-agent", "--token", "token-test"}, exec.Result{})
	r.On("kubectl", []string{"config", "set-context", "devzone", "--cluster", "cluster-hote",
		"--user", "devzone-agent"}, exec.Result{})
	programTokenAuth(r, "yes\n", 0)
	if err := (Kube{Runner: r}).Token(context.Background(), "docker-desktop"); err != nil {
		t.Fatal(err)
	}
	args := strings.Join(r.Calls()[6].Args, " ")
	if !strings.Contains(args, "--certificate-authority=/tmp/account-ca.crt --embed-certs=true") ||
		!strings.Contains(args, "--tls-server-name=hote.internal") {
		t.Fatalf("set-cluster call = %q", args)
	}
}

// TestTokenEmptyIsReported checks that an empty TokenRequest is refused before
// any kubeconfig write.
func TestTokenEmptyIsReported(t *testing.T) {
	_, _, expiry, r := tokenFixture(t)
	programTokenRequest(r, "docker-desktop", []byte("\n2030-01-01T00:00:00Z\n"))
	err := (Kube{Runner: r}).Token(context.Background(), "docker-desktop")
	if !errors.Is(err, ErrTokenEmpty) {
		t.Fatalf("Token = %v, want ErrTokenEmpty", err)
	}
	if len(r.Calls()) != 1 || len(r.Calls()[0].Args) < 3 {
		t.Fatalf("calls = %+v, want only the TokenRequest", r.Calls())
	}
	if _, err := os.Stat(expiry); !os.IsNotExist(err) {
		t.Fatalf("expiry file exists: %v", err)
	}
}

// TestTokenMissingClusterOrServerIsReported checks the messages of the shell
// original when the administrator context has no cluster or server.
func TestTokenMissingClusterOrServerIsReported(t *testing.T) {
	for _, missing := range []string{"cluster", "server"} {
		_, conf, _, r := tokenFixture(t)
		programTokenRequest(r, "docker-desktop", []byte("token-test\n2030-01-01T00:00:00Z\n"))
		clusterOut, serverOut := "cluster-hote\n", "https://127.0.0.1:6443\n"
		if missing == "cluster" {
			clusterOut = ""
		} else {
			serverOut = ""
		}
		r.On("kubectl", []string{"config", "view", "-o",
			`jsonpath={.contexts[?(@.name=="docker-desktop")].context.cluster}`}, exec.Result{Stdout: []byte(clusterOut)})
		r.On("kubectl", []string{"config", "view", "-o",
			`jsonpath={.clusters[?(@.name=="cluster-hote")].cluster.server}`}, exec.Result{Stdout: []byte(serverOut)})
		err := (Kube{Runner: r}).Token(context.Background(), "docker-desktop")
		var message MessageError
		if !errors.As(err, &message) || !strings.HasPrefix(message.Text, missing+" of ") {
			t.Fatalf("Token = %v, want a message about the missing %s", err, missing)
		}
		if missing == "server" && !strings.Contains(message.Text, conf) {
			t.Fatalf("message = %q, want the kubeconfig path", message.Text)
		}
	}
}

// TestTokenOfKindClusterUsesAccountKubeconfig checks that a context absent from
// the host file is read in ~/.kube/config, as for a kind cluster.
func TestTokenOfKindClusterUsesAccountKubeconfig(t *testing.T) {
	home, conf, _, r := tokenFixture(t)
	programTokenRequest(r, "kind-devzone", []byte("token-test\n2030-01-01T00:00:00Z\n"))
	programTokenReads(r, "kind-devzone", "kind-devzone", "https://127.0.0.1:6443", "", "", "")
	programTokenWrites(r, "kind-devzone", "token-test", "")
	if err := (Kube{Runner: r}).Token(context.Background(), "kind-devzone"); err != nil {
		t.Fatal(err)
	}
	if conf != filepath.Join(home, ".kube", "config") {
		t.Fatalf("conf = %q, want ~/.kube/config", conf)
	}
	assertKubeconfig(t, r.Calls(), conf)
}
