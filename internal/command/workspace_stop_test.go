package command

import (
	"bytes"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	fexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/workspace"
)

// stopRunner answers the kubectl and helm calls of "workspace stop" in memory:
// the Argo CD namespace and its workspace Application exist only when argocd is
// true, and every call is recorded in calls. No program runs and no PATH is read.
type stopRunner struct {
	argocd bool
	calls  []string
}

// Kubectl answers the context listing, the Argo CD checks and the Application delete
func (s *stopRunner) Kubectl(args []string, _ io.Reader, stdout, _ io.Writer) (int, error) {
	line := strings.Join(args, " ")
	s.calls = append(s.calls, line)
	switch {
	case line == "config get-contexts -o name":
		_, _ = io.WriteString(stdout, "lab\n")
	case strings.Contains(line, "get namespace"), strings.Contains(line, "get application"):
		if !s.argocd {
			return 1, nil
		}
	}
	return 0, nil
}

// Helm prints its arguments, as the fake helm of the former shell tests did
func (s *stopRunner) Helm(args []string, _ io.Reader, stdout, _ io.Writer) (int, error) {
	s.calls = append(s.calls, "helm "+strings.Join(args, " "))
	_, _ = io.WriteString(stdout, "helm "+strings.Join(args, " ")+"\n")
	return 0, nil
}

// useStopTools injects the kubectl and helm runner and the GitOps runner of
// "workspace stop", with a devzone root and a port state folder of their own, and
// restores the real collaborators at the end of the test.
func useStopTools(t *testing.T, r workspace.Runner, gitops fexec.Runner) {
	t.Helper()
	oldRunner, oldGitops := commandWorkspaceRunner, commandGitopsRunner
	t.Cleanup(func() {
		commandWorkspaceRunner, commandGitopsRunner = oldRunner, oldGitops
	})
	commandWorkspaceRunner, commandGitopsRunner = r, gitops
	t.Setenv("DEVZONE_ROOT", t.TempDir())
	t.Setenv("DEVZONE_PORTS_WORKSPACE_DIR", t.TempDir())
}

// TestWorkspaceStopRunsInGo checks that the stop without argument is answered by
// Go: the helm release is uninstalled through the injected runner.
func TestWorkspaceStopRunsInGo(t *testing.T) {
	r := &stopRunner{}
	useStopTools(t, r, fake.New())
	var out, errOut bytes.Buffer
	if got := Run([]string{"workspace", "stop"}, &out, &errOut); got != 0 {
		t.Fatalf("exit status = %d, want 0 (stderr %q)", got, errOut.String())
	}
	want := "helm uninstall devzone-workspace --namespace devzone-workspace\n"
	if out.String() != want {
		t.Fatalf("stdout = %q, want %q from Go", out.String(), want)
	}
}

// TestWorkspaceStopWithExtraWordsIsIgnored checks that extra words after stop
// are ignored in Go, as the shell entry point ignored them.
func TestWorkspaceStopWithExtraWordsIsIgnored(t *testing.T) {
	r := &stopRunner{}
	useStopTools(t, r, fake.New())
	var out, errOut bytes.Buffer
	if got := Run([]string{"workspace", "stop", "extra"}, &out, &errOut); got != 0 {
		t.Fatalf("exit status = %d, want 0 (stderr %q)", got, errOut.String())
	}
	want := "helm uninstall devzone-workspace --namespace devzone-workspace\n"
	if out.String() != want {
		t.Fatalf("stdout = %q, want %q from Go", out.String(), want)
	}
}

// TestWorkspaceStopWithArgocdDeletesApplication checks that an Argo CD that holds
// the workspace gets the Application deleted in Go, with no GitOps repository.
func TestWorkspaceStopWithArgocdDeletesApplication(t *testing.T) {
	r := &stopRunner{argocd: true}
	useStopTools(t, r, fake.New())
	var out, errOut bytes.Buffer
	if got := Run([]string{"workspace", "stop"}, &out, &errOut); got != 0 {
		t.Fatalf("exit status = %d, want 0 (stderr %q)", got, errOut.String())
	}
	if !strings.Contains(out.String(), "Application devzone-workspace deleted") {
		t.Fatalf("stdout = %q: want the Argo CD removal in Go", out.String())
	}
	for _, c := range r.calls {
		if strings.HasPrefix(c, "helm ") {
			t.Fatalf("helm called although Argo CD holds the workspace: %q", c)
		}
	}
}

// TestWorkspaceStopRefusedGitHubRemovalKeepsApplication checks the end-to-end
// order: a GitHub repository designated in .argocd.conf refuses the DELETE of the
// Application file, so the command fails with 1 and the cluster keeps the
// Application (the bash stop returned 1 here, and ignored no failure of gh).
func TestWorkspaceStopRefusedGitHubRemovalKeepsApplication(t *testing.T) {
	r := &stopRunner{argocd: true}
	gitops := fake.New()
	useStopTools(t, r, gitops)
	root := os.Getenv("DEVZONE_ROOT")
	conf := "[argocd]\nrepo = https://github.com/tester/devzone-argocd.git\n"
	if err := os.WriteFile(filepath.Join(root, ".argocd.conf"), []byte(conf), 0o644); err != nil {
		t.Fatal(err)
	}
	file := "repos/tester/devzone-argocd/contents/apps/devzone-workspace.yaml"
	gitops.On("gh", []string{"api", file, "--jq", ".sha"}, fexec.Result{Stdout: []byte("abc123\n")})
	gitops.On("gh", []string{"api", "-X", "DELETE", file,
		"-f", "message=devzone: application devzone-workspace removed", "-f", "sha=abc123"},
		fexec.Result{Code: 1, Stderr: []byte("HTTP 403\n")})
	var out, errOut bytes.Buffer
	if got := Run([]string{"workspace", "stop"}, &out, &errOut); got != 1 {
		t.Fatalf("exit status = %d, want 1 when the repository refuses the removal", got)
	}
	for _, c := range r.calls {
		if strings.Contains(c, "delete application") {
			t.Fatalf("Application deleted although its file was kept: %q", c)
		}
	}
}
