package kube

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/testkit"
)

// TestAgentConfigMinifiesFromTheSourceKubeconfig checks the agent kubeconfig:
// minified from the source account kubeconfig, mode 600, current context devzone,
// no temporary file left behind.
func TestAgentConfigMinifiesFromTheSourceKubeconfig(t *testing.T) {
	home := testkit.TempHome(t)
	t.Setenv("DEVZONE_KUBE_HOST", filepath.Join(home, ".kube", "hote.config"))
	source := filepath.Join(home, ".kube", "config")
	if err := os.MkdirAll(filepath.Dir(source), 0o755); err != nil {
		t.Fatal(err)
	}
	sourceContent := []byte("apiVersion: v1\nkind: Config\n")
	if err := os.WriteFile(source, sourceContent, 0o600); err != nil {
		t.Fatal(err)
	}
	conf := filepath.Join(home, ".kube", "agent.config")
	t.Setenv("DEVZONE_KUBE_AGENT_CONFIG", conf)
	r := withRunner(t)
	r.On("kubectl", []string{"config", "view", "--minify", "--flatten", "--context", "devzone"}, exec.Result{
		Stdout: sourceContent,
		Code:   0,
	})
	r.On("kubectl", []string{"config", "use-context", "devzone"}, exec.Result{Code: 0})
	api := Kube{Runner: r}
	if err := api.AgentConfig(context.Background()); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(conf)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != string(sourceContent) {
		t.Fatalf("agent config = %q, want %q", got, sourceContent)
	}
	if info, err := os.Stat(conf); err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("agent config mode = %v, %v; want 600", info, err)
	}
	calls := r.Calls()
	if len(calls) != 2 {
		t.Fatalf("calls = %+v, want the view and the context write", calls)
	}
	if len(calls[0].Opts.Env) != 1 || calls[0].Opts.Env[0] != "KUBECONFIG="+source {
		t.Fatalf("view must read the source kubeconfig: %+v", calls[0])
	}
	if len(calls[1].Opts.Env) != 1 || !strings.HasPrefix(calls[1].Opts.Env[0], "KUBECONFIG=") ||
		calls[1].Opts.Env[0] == "KUBECONFIG="+conf || calls[1].Opts.Env[0] == "KUBECONFIG="+source {
		t.Fatalf("context write must use the temporary file: %+v", calls[1])
	}
	entries, err := os.ReadDir(filepath.Dir(conf))
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		if len(e.Name()) > len(".agent.config.") && e.Name()[:14] == ".agent.config." {
			t.Fatalf("temporary file left behind: %s", e.Name())
		}
	}
}

// TestAgentConfigFailingKubectlEmptiesTheFile checks that a failing minify
// empties the agent kubeconfig and returns an error.
func TestAgentConfigFailingKubectlEmptiesTheFile(t *testing.T) {
	home := testkit.TempHome(t)
	t.Setenv("DEVZONE_KUBE_HOST", filepath.Join(home, ".kube", "hote.config"))
	if err := os.MkdirAll(filepath.Join(home, ".kube"), 0o755); err != nil {
		t.Fatal(err)
	}
	conf := filepath.Join(home, ".kube", "agent.config")
	t.Setenv("DEVZONE_KUBE_AGENT_CONFIG", conf)
	r := withRunner(t)
	r.On("kubectl", []string{"config", "view", "--minify", "--flatten", "--context", "devzone"}, exec.Result{
		Code: 1,
	})
	api := Kube{Runner: r}
	if err := api.AgentConfig(context.Background()); err == nil {
		t.Fatal("AgentConfig = nil, want an error")
	}
	got, err := os.ReadFile(conf)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 0 {
		t.Fatalf("agent config = %q, want empty", got)
	}
}

// TestAgentConfigFailingContextWriteEmptiesTheFile checks that a failed
// use-context also empties the agent kubeconfig and leaves no temporary file.
func TestAgentConfigFailingContextWriteEmptiesTheFile(t *testing.T) {
	home := testkit.TempHome(t)
	conf := filepath.Join(home, ".kube", "agent.config")
	if err := os.MkdirAll(filepath.Dir(conf), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(conf, []byte("previous\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("DEVZONE_KUBE_AGENT_CONFIG", conf)
	r := withRunner(t)
	r.On("kubectl", []string{"config", "view", "--minify", "--flatten", "--context", "devzone"}, exec.Result{
		Stdout: []byte("apiVersion: v1\n"),
	})
	r.On("kubectl", []string{"config", "use-context", "devzone"}, exec.Result{Code: 1})
	if err := (Kube{Runner: r}).AgentConfig(context.Background()); err == nil {
		t.Fatal("AgentConfig = nil, want an error")
	}
	got, err := os.ReadFile(conf)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 0 {
		t.Fatalf("agent config = %q, want empty", got)
	}
	entries, err := os.ReadDir(filepath.Dir(conf))
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		if strings.HasPrefix(e.Name(), ".agent.config.") {
			t.Fatalf("temporary file left behind: %s", e.Name())
		}
	}
}
