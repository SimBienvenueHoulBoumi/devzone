package gitlab

import (
	"context"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
)

// TestKubectlUsesCurrentContext checks that every GitLab kubectl wrapper drops
// the services context flag when kubeconfig does not declare that context.
func TestKubectlUsesCurrentContext(t *testing.T) {
	f := newFixture(t)
	f.r = fake.New()
	f.r.On("kubectl", []string{"config", "get-contexts", "-o", "name"},
		exec.Result{Stdout: []byte("kind-poste\n")})
	f.r.On("kubectl", nil, exec.Result{Stdout: []byte("ok\n")})
	r := newRun(context.Background(), f.opts())
	if _, err := r.kubectlDevzone([]string{"get", "namespace", "devzone-argocd"}); err != nil {
		t.Fatal(err)
	}
	if _, err := r.kubectlDevzoneWithStdin([]string{"apply", "-f", "-"}, "kind: X\n"); err != nil {
		t.Fatal(err)
	}
	if _, err := r.execStdin([]string{"exec", "-i", "pod"}, "puts 1\n"); err != nil {
		t.Fatal(err)
	}
	if _, err := r.execStdinOut([]string{"exec", "-i", "pod"}, "puts 1\n"); err != nil {
		t.Fatal(err)
	}
	for _, call := range f.r.Calls() {
		if call.Name != "kubectl" {
			continue
		}
		line := strings.Join(call.Args, " ")
		if strings.Contains(line, "--context devzone") {
			t.Errorf("services context was forced on a workstation without it: %q", line)
		}
	}
}
