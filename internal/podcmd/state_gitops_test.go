package podcmd

import (
	"errors"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
)

// kubectlAppArgs are the exact kubectl arguments used by runStateGitopsLine.
var kubectlAppArgs = []string{
	"get", "application", "devzone", "-n", "devzone-argocd",
	"-o", "jsonpath={.spec.source.repoURL}", "--request-timeout=5s",
}

// TestShellGitopsStateLineGoEquivalent checks frozen gitops_state_line output
// and exit code (formerly gitops_state_line from state-gitops.sh vs
// runStateGitopsLine), with a fake kubectl, taken from the shell comparison
// before state-gitops.sh was removed.
func TestShellGitopsStateLineGoEquivalent(t *testing.T) {
	t.Setenv("GITOPS_NS", "devzone-argocd")
	for _, tc := range []struct {
		name string
		url  string
		err  error
		want string
	}{
		{"present", "https://github.com/tester/devzone-argocd.git", nil, "  ○ argocd          GitOps repository: https://github.com/tester/devzone-argocd.git\n"},
		{"absent", "", errors.New("not found"), "  ○ argocd          managed from the workstation: devzone workspace argocd status\n"},
		{"forbidden", "", errors.New("forbidden"), "  ○ argocd          managed from the workstation: devzone workspace argocd status\n"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			runner := fake.New()
			if tc.err != nil {
				runner.OnError("kubectl", kubectlAppArgs, exec.Result{}, tc.err)
			} else {
				runner.On("kubectl", kubectlAppArgs, exec.Result{Stdout: []byte(tc.url + "\n")})
			}
			var goOut strings.Builder
			ctx := &cli.Context{Out: &goOut, Err: &strings.Builder{}, Runner: runner}
			goCode := runStateGitopsLine(ctx)
			if goCode != 0 { // frozen shell code 0
				t.Fatalf("code %d, want frozen code 0", goCode)
			}
			if goOut.String() != tc.want {
				t.Fatalf("output %q, want %q", goOut.String(), tc.want)
			}
		})
	}
}
