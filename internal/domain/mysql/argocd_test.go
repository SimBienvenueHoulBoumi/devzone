package mysql

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"testing"
)

// TestArgoCDLibraryCall checks the arguments and the devzone folder received by
// the shell Argo CD library, run by a real bash.
func TestArgoCDLibraryCall(t *testing.T) {
	root := t.TempDir()
	codeRoot := filepath.Join(root, ".devcontainer")
	if err := os.MkdirAll(filepath.Join(codeRoot, "argocd"), 0o755); err != nil {
		t.Fatal(err)
	}
	lib := "catalogue_argocd_apply() { printf '%s|' \"$RACINE\" \"$@\"; }\n"
	if err := os.WriteFile(filepath.Join(codeRoot, "argocd", "catalog-argocd.sh"), []byte(lib), 0o644); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"MYSQL_IMAGE", "MYSQL_PORT", "MYSQL_MEMOIRE", "MYSQL_TAILLE"} {
		t.Setenv(name, "")
	}
	var out bytes.Buffer
	e := newEnv(context.Background(), Options{Root: root, CodeRoot: codeRoot, StatePath: filepath.Join(root, "state"), Out: &out})
	if err := e.argocdApply(ns, "claim=data"); err != nil {
		t.Fatal(err)
	}
	want := root + "|mysql|devzone-mysql|mysql:8.4|3306|1Gi|5Gi|claim=data|"
	if out.String() != want {
		t.Fatalf("call = %q, want %q", out.String(), want)
	}
}
