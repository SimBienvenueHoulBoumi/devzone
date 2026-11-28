package command

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
)

// TestServicesContextDefaultName: without DEVZONE_CONTEXT the kubeconfig
// context named devzone is the services context the uninstall works on.
func TestServicesContextDefaultName(t *testing.T) {
	t.Setenv("DEVZONE_CONTEXT", "")
	runner := fake.New()
	runner.On("kubectl", []string{"config", "get-contexts", "-o", "name"},
		exec.Result{Stdout: []byte("kind-poste\ndevzone\n")})
	got, err := servicesContext(context.Background(), runner, t.TempDir())
	if err != nil {
		t.Fatalf("servicesContext: %v", err)
	}
	if got != "devzone" {
		t.Fatalf("servicesContext = %q, want devzone", got)
	}
}

// TestServicesContextOverriddenName: DEVZONE_CONTEXT names the context of the
// uninstall, so the default literal is never returned.
func TestServicesContextOverriddenName(t *testing.T) {
	t.Setenv("DEVZONE_CONTEXT", "autre")
	runner := fake.New()
	runner.On("kubectl", []string{"config", "get-contexts", "-o", "name"},
		exec.Result{Stdout: []byte("kind-poste\ndevzone\nautre\n")})
	got, err := servicesContext(context.Background(), runner, t.TempDir())
	if err != nil {
		t.Fatalf("servicesContext: %v", err)
	}
	if got != "autre" {
		t.Fatalf("servicesContext = %q, want autre", got)
	}
}

// TestServicesContextOverriddenMissing: when the kubeconfig does not declare
// the overridden name, no context is returned and the failure names it.
func TestServicesContextOverriddenMissing(t *testing.T) {
	t.Setenv("DEVZONE_CONTEXT", "autre")
	runner := fake.New()
	runner.On("kubectl", []string{"config", "get-contexts", "-o", "name"},
		exec.Result{Stdout: []byte("devzone\n")})
	got, err := servicesContext(context.Background(), runner, t.TempDir())
	if !errors.Is(err, errNoServicesCluster) {
		t.Fatalf("err = %v, want errNoServicesCluster", err)
	}
	if !strings.Contains(err.Error(), "autre") {
		t.Fatalf("err = %q, want the overridden name in it", err)
	}
	if got != "" {
		t.Fatalf("servicesContext = %q, want empty", got)
	}
}
