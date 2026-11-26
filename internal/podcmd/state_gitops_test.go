package podcmd

import (
	"os"
	osexec "os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// TestShellGitopsStateLineGoEquivalent checks gitops_state_line from
// origin/develop state-gitops.sh vs runStateGitopsLine, with a fake kubectl.
func TestShellGitopsStateLineGoEquivalent(t *testing.T) {
	repo := repoRootForGitops(t)
	dir := t.TempDir()
	out, err := osexec.Command("git", "-C", repo, "show", "origin/develop:.devcontainer/state-gitops.sh").Output()
	if err != nil {
		t.Fatal(err)
	}
	script := filepath.Join(dir, "state-gitops.sh")
	if err := os.WriteFile(script, out, 0o644); err != nil {
		t.Fatal(err)
	}
	bin := filepath.Join(dir, "bin")
	if err := os.MkdirAll(bin, 0o755); err != nil {
		t.Fatal(err)
	}
	kube := `#!/usr/bin/env bash
case "${FAUX_APP:-absent}" in
    present) printf '%s\n' "${FAUX_URL:-https://github.com/tester/devzone-argocd.git}"; exit 0 ;;
    *) exit 1 ;;
esac
`
	if err := os.WriteFile(filepath.Join(bin, "kubectl"), []byte(kube), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("GITOPS_NS", "devzone-argocd")

	for _, tc := range []struct {
		name string
		app  string
		url  string
		want string
	}{
		{"present", "present", "https://github.com/tester/devzone-argocd.git", "  ○ argocd          GitOps repository: https://github.com/tester/devzone-argocd.git\n"},
		{"absent", "absent", "", "  ○ argocd          managed from the workstation: devzone workspace argocd status\n"},
		{"forbidden", "forbidden", "", "  ○ argocd          managed from the workstation: devzone workspace argocd status\n"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv("FAUX_APP", tc.app)
			t.Setenv("FAUX_URL", tc.url)
			shellCmd := osexec.Command("bash", "-c", `. "$1"; gitops_state_line`, "_", script)
			shellCmd.Env = append(os.Environ(), "PATH="+bin+string(os.PathListSeparator)+os.Getenv("PATH"), "FAUX_APP="+tc.app, "FAUX_URL="+tc.url, "GITOPS_NS=devzone-argocd")
			shellOut, shellErr := shellCmd.Output()
			shellCode := 0
			if shellErr != nil {
				if ex, ok := shellErr.(*osexec.ExitError); ok {
					shellCode = ex.ExitCode()
				} else {
					t.Fatalf("shell: %v", shellErr)
				}
			}
			var goOut strings.Builder
			ctx := &cli.Context{Out: &goOut, Err: &strings.Builder{}, Runner: exec.ExecRunner{}}
			goCode := runStateGitopsLine(ctx)
			if goCode != shellCode || goOut.String() != string(shellOut) {
				t.Fatalf("shell code=%d out=%q Go code=%d out=%q", shellCode, shellOut, goCode, goOut.String())
			}
			if goOut.String() != tc.want {
				t.Fatalf("unexpected output %q", goOut.String())
			}
		})
	}
}

func repoRootForGitops(t *testing.T) string {
	t.Helper()
	out, err := osexec.Command("git", "rev-parse", "--show-toplevel").Output()
	if err != nil {
		t.Fatal(err)
	}
	return strings.TrimSpace(string(out))
}
