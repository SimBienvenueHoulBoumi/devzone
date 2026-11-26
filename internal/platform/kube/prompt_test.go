package kube

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/testkit"
)

// promptSetup creates a disposable home, kubeconfig and cache for one prompt test.
func promptSetup(t *testing.T) (*Kube, string, string) {
	t.Helper()
	home := testkit.TempHome(t)
	conf := filepath.Join(home, ".kube", "config")
	if err := os.MkdirAll(filepath.Dir(conf), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(conf, []byte("kubeconfig: test\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("KUBECONFIG", conf)
	cacheDir := filepath.Join(home, "cache")
	t.Setenv("XDG_CACHE_HOME", cacheDir)
	r := withRunner(t)
	r.On("kubectl", nil, exec.Result{})
	r.On("kubectl", []string{"config", "current-context"}, exec.Result{Stdout: []byte("rancher-desktop\n")})
	r.On("kubectl", []string{"config", "view", "-o", `jsonpath={.contexts[?(@.name=="rancher-desktop")].context.namespace}`}, exec.Result{})
	return &Kube{Runner: r}, conf, filepath.Join(cacheDir, "devzone-kube-prompt")
}

// TestPromptCachesResult checks that a second call with the same signature runs
// no kubectl command and prints the cached line.
func TestPromptCachesResult(t *testing.T) {
	k, _, cache := promptSetup(t)
	var first, second bytes.Buffer
	if err := k.Prompt(context.Background(), &first); err != nil {
		t.Fatal(err)
	}
	r := k.Runner.(*fake.Runner)
	calls := len(r.Calls())
	if err := k.Prompt(context.Background(), &second); err != nil {
		t.Fatal(err)
	}
	if first.String() != second.String() || !strings.Contains(first.String(), "rancher-desktop/default") {
		t.Fatalf("first = %q, second = %q", first.String(), second.String())
	}
	if len(r.Calls()) != calls {
		t.Fatalf("cache miss: calls %d then %d", calls, len(r.Calls()))
	}
	data, err := os.ReadFile(cache)
	if err != nil || !strings.Contains(string(data), "rancher-desktop/default") {
		t.Fatalf("cache = %q, err %v", data, err)
	}
}

// TestPromptColourMarkers checks the non-printing markers around the colours.
func TestPromptColourMarkers(t *testing.T) {
	k, _, _ := promptSetup(t)
	var out bytes.Buffer
	if err := k.Prompt(context.Background(), &out); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), "\001\033[36m\002") || !strings.Contains(out.String(), "\001\033[0m\002") {
		t.Fatalf("prompt = %q", out.String())
	}
}

// TestPromptRemoteContext checks the red remote rendering.
func TestPromptRemoteContext(t *testing.T) {
	k, _, _ := promptSetup(t)
	r := k.Runner.(*fake.Runner)
	r.On("kubectl", []string{"config", "current-context"}, exec.Result{Stdout: []byte("prod\n")})
	r.On("kubectl", []string{"config", "view", "-o", `jsonpath={.contexts[?(@.name=="prod")].context.cluster}`}, exec.Result{Stdout: []byte("prod-cluster\n")})
	r.On("kubectl", []string{"config", "view", "-o", `jsonpath={.clusters[?(@.name=="prod-cluster")].cluster.server}`}, exec.Result{Stdout: []byte("https://prod.example.test:6443\n")})
	var out bytes.Buffer
	if err := k.Prompt(context.Background(), &out); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), "\001\033[1;31m\002⎈ prod/default remote") {
		t.Fatalf("prompt = %q", out.String())
	}
}

// TestPromptSignatureChangesWhenConfigChanges checks that a new mtime is a
// cache miss and refreshes the prompt.
func TestPromptSignatureChangesWhenConfigChanges(t *testing.T) {
	k, conf, _ := promptSetup(t)
	var out bytes.Buffer
	if err := k.Prompt(context.Background(), &out); err != nil {
		t.Fatal(err)
	}
	r := k.Runner.(*fake.Runner)
	calls := len(r.Calls())
	later := time.Now().Add(7200 * time.Second)
	if err := os.Chtimes(conf, later, later); err != nil {
		t.Fatal(err)
	}
	if err := k.Prompt(context.Background(), &out); err != nil {
		t.Fatal(err)
	}
	if len(r.Calls()) <= calls {
		t.Fatalf("mtime change did not refresh the prompt: calls %d then %d", calls, len(r.Calls()))
	}
}
