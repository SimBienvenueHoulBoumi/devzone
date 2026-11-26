package mysql

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"testing"

	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
)

// TestArgoCDLibraryCall checks that argocdApply delegates to the Go Argo CD
// module with the MySQL chart values.
func TestArgoCDLibraryCall(t *testing.T) {
	root := t.TempDir()
	codeRoot := filepath.Join(root, ".devcontainer")
	if err := os.MkdirAll(filepath.Join(codeRoot, "argocd"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, "charts", "devzone-mysql"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "charts", "devzone-mysql", "Chart.yaml"), []byte("name: devzone-mysql\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	runner := fake.New()
	runner.On("kubectl", nil, fexec.Result{})
	t.Setenv("DEVZONE_ARGOCD_REVISION", "v1.0.0")
	var out bytes.Buffer
	e := newEnv(context.Background(), Options{Root: root, CodeRoot: codeRoot, StatePath: filepath.Join(root, "state"), Out: &out, Runner: runner})
	if err := e.argocdApply(ns, "claim=data"); err != nil {
		t.Fatal(err)
	}
}
