package exec

import (
	"context"
	"reflect"
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

// TestDevzoneContextFlagUsesContextName checks that the flag carries the
// configured name when kubeconfig declares it, and nothing when it does not.
func TestDevzoneContextFlagUsesContextName(t *testing.T) {
	t.Setenv("DEVZONE_CONTEXT", "kind-lab")
	wantFlag := []string{"--context", "kind-lab"}
	got := DevzoneContextFlag(context.Background(), contextRunner{names: "kind-poste\nkind-lab\n"}, "--context")
	if !reflect.DeepEqual(got, wantFlag) {
		t.Fatalf("flag = %v, want %v", got, wantFlag)
	}
	got = DevzoneContextFlag(context.Background(), contextRunner{names: "kind-poste\n"}, "--context")
	if len(got) != 0 {
		t.Fatalf("flag = %v, want none", got)
	}
	wantHelm := []string{"--kube-context", "kind-lab"}
	got = DevzoneContextFlag(context.Background(), contextRunner{names: "kind-lab\n"}, "--kube-context")
	if !reflect.DeepEqual(got, wantHelm) {
		t.Fatalf("helm flag = %v, want %v", got, wantHelm)
	}
}
