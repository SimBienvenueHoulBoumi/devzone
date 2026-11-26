package podcmd

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
)

// TestRunArgocdUsesResolvedRoot checks that the Go command reads the state and
// the charts of the devzone root and code folder, never those of the current
// directory, when DEVZONE_ROOT is not set.
func TestRunArgocdUsesResolvedRoot(t *testing.T) {
	root := t.TempDir()
	code := filepath.Join(root, ".devcontainer")
	if err := os.MkdirAll(code, 0o755); err != nil {
		t.Fatal(err)
	}
	script := filepath.Join(code, "devzone")
	if err := os.WriteFile(script, []byte("#!/usr/bin/env bash\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, ".devzone.modules"), []byte("argocd=off\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	chart := filepath.Join(root, "charts", "devzone-postgres")
	if err := os.MkdirAll(chart, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(chart, "Chart.yaml"), []byte("name: devzone-postgres\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "package.json"), []byte("{\"version\": \"1.2.3\"}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	other := t.TempDir()
	if err := os.WriteFile(filepath.Join(other, ".devzone.modules"), []byte("argocd=on\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Chdir(other)
	t.Setenv("DEVZONE_POD_SCRIPT", script)
	t.Setenv("DEVZONE_ROOT", "")
	t.Setenv("DEVZONE_STATE", "")
	t.Setenv("HOME", t.TempDir())

	r := fake.New()
	r.On("kubectl", nil, fexec.Result{})
	r.On("bash", nil, fexec.Result{})
	var out, errOut bytes.Buffer
	ctx := &cli.Context{Args: []string{"catalog-active", "postgres"}, Out: &out, Err: &errOut, Runner: r}
	if code := runArgocd(ctx); code != 1 {
		t.Fatalf("catalog-active: code=%d out=%q err=%q", code, out.String(), errOut.String())
	}
	out.Reset()
	ctx.Args = []string{"chart-require", "postgres"}
	if code := runArgocd(ctx); code != 0 {
		t.Fatalf("chart-require: code=%d out=%q err=%q", code, out.String(), errOut.String())
	}
}

// TestRunArgocdWithoutRootNeverUsesCurrentFolder checks that an unresolved
// root is refused instead of silently reading the current directory.
func TestRunArgocdWithoutRootNeverUsesCurrentFolder(t *testing.T) {
	other := t.TempDir()
	if err := os.WriteFile(filepath.Join(other, ".devzone.modules"), []byte("argocd=off\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Chdir(other)
	t.Setenv("DEVZONE_ROOT", "")
	t.Setenv("DEVZONE_STATE", "")
	t.Setenv("DEVZONE_POD_SCRIPT", "")
	old := defaultScript
	defaultScript = filepath.Join(t.TempDir(), "absent")
	t.Cleanup(func() { defaultScript = old })
	var out, errOut bytes.Buffer
	ctx := &cli.Context{Args: []string{"status"}, Out: &out, Err: &errOut, Runner: fake.New()}
	if code := runArgocd(ctx); code != 1 || !strings.Contains(errOut.String(), "devzone root unavailable") {
		t.Fatalf("status: code=%d out=%q err=%q", code, out.String(), errOut.String())
	}
}
