package command

import (
	"bytes"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/workspace"
)

// updateTestRunner answers the read-only cluster calls of an update: the Argo CD
// namespace exists only when installed, and every other query is empty.
type updateTestRunner struct{ installed bool }

// Kubectl answers the Argo CD namespace probe and gives no Application, so the
// workspace is never considered up to date.
func (r updateTestRunner) Kubectl(args []string, _ io.Reader, _, _ io.Writer) (int, error) {
	if strings.Contains(strings.Join(args, " "), "get namespace devzone-argocd") && !r.installed {
		return 1, nil
	}
	return 0, nil
}

// Helm succeeds: an update only reaches helm when Argo CD does not hold it.
func (updateTestRunner) Helm(_ []string, _ io.Reader, _, _ io.Writer) (int, error) {
	return 0, nil
}

// stubUpdate replaces the collaborators of the update for one test and restores
// them afterwards.
func stubUpdate(t *testing.T, installed bool) {
	t.Helper()
	runner, tags, image := updateRunner, updateTags, updateImageExists
	deploy, reconcile, ready := updateDeploy, updateReconcile, updateReady
	t.Cleanup(func() {
		updateRunner, updateTags, updateImageExists = runner, tags, image
		updateDeploy, updateReconcile, updateReady = deploy, reconcile, ready
	})
	updateRunner = updateTestRunner{installed: installed}
	updateTags = func(string) []string { return []string{"v0.1.0"} }
	updateImageExists = func(string) bool { return true }
	updateReady = func(workspace.Runner) (string, bool) { return "", true }
}

// writeModules writes the state file of the temporary devzone folder.
func writeModules(t *testing.T, content string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(".", ".devzone.modules"), []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

// TestUpdateCommandDeploysLatestRelease checks that the command resolves the
// release, deploys it and reports it, with no reconcile without Argo CD.
func TestUpdateCommandDeploysLatestRelease(t *testing.T) {
	t.Chdir(t.TempDir())
	writeModules(t, "argocd=off\n")
	stubUpdate(t, false)
	var deployed []string
	updateDeploy = func(_ *cli.Context, repository, tag, revision string) int {
		deployed = []string{repository, tag, revision}
		return 0
	}
	updateReconcile = func(*cli.Context) int { t.Fatal("reconcile without Argo CD"); return 1 }
	var out, errOut bytes.Buffer
	ctx := &cli.Context{Args: []string{"update", "--yes"}, Out: &out, Err: &errOut}
	if code := workspaceCommand(ctx); code != 0 {
		t.Fatalf("status = %d, stderr = %q", code, errOut.String())
	}
	if strings.Join(deployed, " ") != "ghcr.io/simbienvenuehoulboumi/devzone-workspace 0.1.0 v0.1.0" {
		t.Fatalf("deploy = %v", deployed)
	}
	if !strings.Contains(out.String(), "workspace on v0.1.0") {
		t.Fatalf("stdout = %q", out.String())
	}
}

// TestUpdateCommandReconcilesWithArgoCD checks that the service Applications
// are reconciled after a deploy when Argo CD is installed and wanted.
func TestUpdateCommandReconcilesWithArgoCD(t *testing.T) {
	t.Chdir(t.TempDir())
	writeModules(t, "argocd=on\n")
	stubUpdate(t, true)
	updateDeploy = func(*cli.Context, string, string, string) int { return 0 }
	reconciled := 0
	updateReconcile = func(*cli.Context) int { reconciled++; return 0 }
	var out, errOut bytes.Buffer
	ctx := &cli.Context{Args: []string{"update", "--version", "0.2.0", "--yes"}, Out: &out, Err: &errOut}
	if code := workspaceCommand(ctx); code != 0 {
		t.Fatalf("status = %d, stderr = %q", code, errOut.String())
	}
	if reconciled != 1 {
		t.Fatalf("reconcile calls = %d, want 1", reconciled)
	}
}

// TestUpdateCommandRefusesBadOption checks that a wrong option stops before any
// deploy and keeps the status of the shell.
func TestUpdateCommandRefusesBadOption(t *testing.T) {
	t.Chdir(t.TempDir())
	writeModules(t, "argocd=off\n")
	stubUpdate(t, false)
	updateDeploy = func(*cli.Context, string, string, string) int { t.Fatal("deploy after a bad option"); return 1 }
	var out, errOut bytes.Buffer
	ctx := &cli.Context{Args: []string{"update", "--force"}, Out: &out, Err: &errOut}
	if code := workspaceCommand(ctx); code != 1 {
		t.Fatalf("status = %d, want 1", code)
	}
	if !strings.Contains(errOut.String(), "unknown option: --force") {
		t.Fatalf("stderr = %q", errOut.String())
	}
}
