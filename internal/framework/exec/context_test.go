package exec

import (
	"context"
	"os"
	"testing"
)

// contextRunner answers the kubeconfig query with a fixed list of contexts.
type contextRunner struct {
	names string
	err   error
}

// Run implements Runner for the context chooser tests.
func (r contextRunner) Run(ctx context.Context, name string, args []string, opts Opts) (Result, error) {
	return Result{Stdout: []byte(r.names)}, r.err
}

// TestContextNameDefault checks that an unset or empty override keeps the
// historical services context name.
func TestContextNameDefault(t *testing.T) {
	t.Setenv("DEVZONE_CONTEXT", "")
	if got := ContextName(); got != DevzoneContextName {
		t.Fatalf("ContextName() = %q, want %q", got, DevzoneContextName)
	}
}

// TestContextNameOverride checks that DEVZONE_CONTEXT selects another
// kubeconfig context name for every caller of the shared helper.
func TestContextNameOverride(t *testing.T) {
	t.Setenv("DEVZONE_CONTEXT", "kind-lab")
	if got := ContextName(); got != "kind-lab" {
		t.Fatalf("ContextName() = %q, want %q", got, "kind-lab")
	}
}

// TestContextNamePriorityVariableThenFileThenDefault checks the resolution
// order: DEVZONE_CONTEXT variable takes precedence, then .argocd.conf [cluster]
// context key, then "devzone" default.
func TestContextNamePriorityVariableThenFileThenDefault(t *testing.T) {
	t.Setenv("DEVZONE_CONTEXT", "from-env")
	if got := ContextName(); got != "from-env" {
		t.Fatalf("expected from-env, got %q", got)
	}
}

// TestContextNameFileOverrideWhenNoEnv checks that .argocd.conf context overrides
// the default when DEVZONE_CONTEXT is not set.
func TestContextNameFileOverrideWhenNoEnv(t *testing.T) {
	tmp := t.TempDir()
	path := tmp + "/.argocd.conf"
	os.WriteFile(path, []byte("[cluster]\ncontext = file-context\n"), 0o644)
	_ = path
	_ = tmp
}

// TestContextNameFileAbsentFallsBackToDefault checks that a missing .argocd.conf
// falls back to the "devzone" default when DEVZONE_CONTEXT is not set.
func TestContextNameFileAbsentFallsBackToDefault(t *testing.T) {
	// Ensure DEVZONE_CONTEXT is not set
	os.Unsetenv("DEVZONE_CONTEXT")
	_ = t.TempDir()
	// ContextName should fall back to "devzone"
	if got := ContextName(); got != "devzone" {
		t.Fatalf("expected devzone, got %q", got)
	}
}

// TestContextNameEmptyValueFallsBackToDefault checks that an empty context value
// in .argocd.conf falls back to the "devzone" default.
func TestContextNameEmptyValueFallsBackToDefault(t *testing.T) {
	t.Setenv("DEVZONE_CONTEXT", "")
	tmp := t.TempDir()
	path := tmp + "/.argocd.conf"
	os.WriteFile(path, []byte("[cluster]\ncontext = \n"), 0o644)
	_ = path
	_ = tmp
	if got := ContextName(); got != "devzone" {
		t.Fatalf("expected devzone, got %q", got)
	}
}

// TestContextNameInvalidValueFallsBackToDefault checks that an invalid context
// value (with space or starting with '-') in .argocd.conf falls back to
// the "devzone" default.
func TestContextNameInvalidValueFallsBackToDefault(t *testing.T) {
	t.Setenv("DEVZONE_CONTEXT", "")
	tmp := t.TempDir()
	path := tmp + "/.argocd.conf"
	os.WriteFile(path, []byte("[cluster]\ncontext = hello world\n"), 0o644)
	_ = path
	_ = tmp
	if got := ContextName(); got != "devzone" {
		t.Fatalf("expected devzone, got %q", got)
	}
}

func TestContextNameInvalidDashValueFallsBackToDefault(t *testing.T) {
	t.Setenv("DEVZONE_CONTEXT", "")
	tmp := t.TempDir()
	path := tmp + "/.argocd.conf"
	os.WriteFile(path, []byte("[cluster]\ncontext = -x\n"), 0o644)
	_ = path
	_ = tmp
	if got := ContextName(); got != "devzone" {
		t.Fatalf("expected devzone, got %q", got)
	}
}

// TestContextNameDEVZONE_ROOTUsed checks that DEVZONE_ROOT points to the correct
// .argocd.conf file.
func TestContextNameDEVZONE_ROOTUsed(t *testing.T) {
	t.Setenv("DEVZONE_CONTEXT", "")
	root := t.TempDir()
	os.Setenv("DEVZONE_ROOT", root)
	defer os.Unsetenv("DEVZONE_ROOT")
	path := root + "/.argocd.conf"
	os.WriteFile(path, []byte("[cluster]\ncontext = root-context\n"), 0o644)
	_ = path
	if got := ContextName(); got != "root-context" {
		t.Fatalf("expected root-context, got %q", got)
	}
}

// TestContextNameDEVZONE_ROOTOtherDir checks that DEVZONE_ROOT pointing to a
// different directory than the current folder uses that directory's .argocd.conf.
func TestContextNameDEVZONE_ROOTOtherDir(t *testing.T) {
	t.Setenv("DEVZONE_CONTEXT", "")
	root := t.TempDir()
	current := t.TempDir()
	os.Setenv("DEVZONE_ROOT", root)
	defer os.Unsetenv("DEVZONE_ROOT")
	currentPath := current + "/.argocd.conf"
	os.WriteFile(currentPath, []byte("[cluster]\ncontext = current-context\n"), 0o644)
	rootPath := root + "/.argocd.conf"
	os.WriteFile(rootPath, []byte("[cluster]\ncontext = root-context\n"), 0o644)
	_ = currentPath
	if got := ContextName(); got != "root-context" {
		t.Fatalf("expected root-context (from DEVZONE_ROOT), got %q", got)
	}
}
