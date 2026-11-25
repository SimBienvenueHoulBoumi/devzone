package kube

import (
	"context"
	"errors"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// TestTokenFailsWhenAContextWriteFails checks every write of the devzone
// context: a failure stops the renewal and leaves no expiry file.
func TestTokenFailsWhenAContextWriteFails(t *testing.T) {
	failures := [][]string{
		{"config", "set-cluster", "cluster-hote", "--server=https://127.0.0.1:6443"},
		{"config", "set", "clusters.cluster-hote.certificate-authority-data", "Y2EtdGVzdAo="},
		{"config", "set-credentials", "devzone-agent", "--token", "token-test"},
		{"config", "set-context", "devzone", "--cluster", "cluster-hote", "--user", "devzone-agent"},
	}
	for _, failure := range failures {
		_, _, expiry, r := tokenFixture(t)
		programTokenRequest(r, "docker-desktop", []byte("token-test\n2030-01-01T00:00:00Z\n"))
		programTokenReads(r, "docker-desktop", "cluster-hote", "https://127.0.0.1:6443", "Y2EtdGVzdAo=", "", "")
		programTokenWrites(r, "cluster-hote", "token-test", "Y2EtdGVzdAo=")
		r.On("kubectl", failure, exec.Result{Code: 1})
		if err := (Kube{Runner: r}).Token(context.Background(), "docker-desktop"); err == nil {
			t.Fatalf("Token with failing %v = nil, want an error", failure)
		}
		if _, err := os.Stat(expiry); !os.IsNotExist(err) {
			t.Fatalf("expiry file written after failing %v: %v", failure, err)
		}
	}
}

// TestTokenAcceptsAuthNoWithExitCodeOne checks that a reachable context that
// denies the auth check still gets a token and an expiry file.
func TestTokenAcceptsAuthNoWithExitCodeOne(t *testing.T) {
	_, _, expiry, r := tokenFixture(t)
	programTokenRequest(r, "docker-desktop", []byte("token-test\n2030-01-01T00:00:00Z\n"))
	programTokenReads(r, "docker-desktop", "cluster-hote", "https://127.0.0.1:6443", "Y2EtdGVzdAo=", "", "")
	programTokenWrites(r, "cluster-hote", "token-test", "Y2EtdGVzdAo=")
	programTokenAuth(r, "no\n", 1)
	if err := (Kube{Runner: r}).Token(context.Background(), "docker-desktop"); err != nil {
		t.Fatalf("Token = %v, want the answer no to be accepted", err)
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
}

// TestTokenUnreachableContextRemovesExpiry checks that an answer other than
// yes or no (here Unauthorized) is refused and deletes the old expiry file.
func TestTokenUnreachableContextRemovesExpiry(t *testing.T) {
	_, _, expiry, r := tokenFixture(t)
	if err := os.WriteFile(expiry, []byte("1234\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	programTokenRequest(r, "docker-desktop", []byte("token-test\n2030-01-01T00:00:00Z\n"))
	programTokenReads(r, "docker-desktop", "cluster-hote", "https://127.0.0.1:6443", "Y2EtdGVzdAo=", "", "")
	programTokenWrites(r, "cluster-hote", "token-test", "Y2EtdGVzdAo=")
	programTokenAuth(r, "Error from server (Unauthorized)\n", 1)
	err := (Kube{Runner: r}).Token(context.Background(), "docker-desktop")
	if !errors.Is(err, ErrTokenContextNotReachable) || err.Error() != "limited account context not reachable" {
		t.Fatalf("Token = %v, want ErrTokenContextNotReachable", err)
	}
	if _, err := os.Stat(expiry); !os.IsNotExist(err) {
		t.Fatalf("old expiry file not removed: %v", err)
	}
}

// TestTokenExpiryFallsBackToTwentyFourHours checks the expiry file when the
// TokenRequest response has no readable expiration timestamp.
func TestTokenExpiryFallsBackToTwentyFourHours(t *testing.T) {
	_, _, expiry, r := tokenFixture(t)
	programTokenRequest(r, "docker-desktop", []byte("token-test\n"))
	programTokenReads(r, "docker-desktop", "cluster-hote", "https://127.0.0.1:6443", "", "", "")
	programTokenWrites(r, "cluster-hote", "token-test", "")
	before := time.Now().Unix()
	if err := (Kube{Runner: r}).Token(context.Background(), "docker-desktop"); err != nil {
		t.Fatal(err)
	}
	after := time.Now().Unix()
	data, err := os.ReadFile(expiry)
	if err != nil {
		t.Fatal(err)
	}
	value, err := strconv.ParseInt(strings.TrimSpace(string(data)), 10, 64)
	if err != nil {
		t.Fatal(err)
	}
	if value < before+86400 || value > after+86400 {
		t.Fatalf("expiry = %d, want between %d and %d", value, before+86400, after+86400)
	}
	if info, err := os.Stat(expiry); err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("expiry mode = %v, %v; want 600", info, err)
	}
}

// TestTokenReadsAuthorityWithRaw checks that the certificate authority is read
// with --raw: the masked DATA+OMITTED value of a plain view is never used.
func TestTokenReadsAuthorityWithRaw(t *testing.T) {
	_, _, _, r := tokenFixture(t)
	programTokenRequest(r, "docker-desktop", []byte("token-test\n2030-01-01T00:00:00Z\n"))
	programTokenReads(r, "docker-desktop", "cluster-hote", "https://127.0.0.1:6443", "Y2EtdGVzdAo=", "", "")
	r.On("kubectl", []string{"config", "view", "-o",
		`jsonpath={.clusters[?(@.name=="cluster-hote")].cluster.certificate-authority-data}`}, exec.Result{
		Stdout: []byte("DATA+OMITTED\n"),
	})
	programTokenWrites(r, "cluster-hote", "token-test", "Y2EtdGVzdAo=")
	if err := (Kube{Runner: r}).Token(context.Background(), "docker-desktop"); err != nil {
		t.Fatal(err)
	}
	for _, call := range r.Calls() {
		for _, arg := range call.Args {
			if strings.Contains(arg, "DATA+OMITTED") {
				t.Fatalf("masked certificate authority used: %+v", call)
			}
		}
	}
}
