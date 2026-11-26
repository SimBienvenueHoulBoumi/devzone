package agent

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	dzexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// kubectlFake is a scripted kubectl; records calls.
type kubectlFake struct {
	resp  func(args []string) dzexec.Result
	calls [][]string
}

// Run records kubectl calls and returns the scripted response.
func (k *kubectlFake) Run(ctx context.Context, name string, args []string, opts dzexec.Opts) (dzexec.Result, error) {
	if name == "kubectl" {
		k.calls = append(k.calls, append([]string{}, args...))
		if k.resp != nil {
			return k.resp(args), nil
		}
	}
	return dzexec.Result{Code: 0}, nil
}

// fauxWorktree creates a worktree folder with a .git file pointing inside the root.
func fauxWorktree(t *testing.T, root, depot, nom string) string {
	t.Helper()
	folder := filepath.Join(root, depot+"-wt", nom)
	os.MkdirAll(folder, 0o755)
	os.MkdirAll(filepath.Join(root, depot, ".git", "worktrees", nom), 0o755)
	os.WriteFile(filepath.Join(folder, ".git"), []byte("gitdir: "+filepath.Join(root, depot, ".git", "worktrees", nom)+"\n"), 0o644)
	return folder
}

// TestAgentPodPathOK checks that only folders under the projects root with a
// simple relative path are accepted.
func TestAgentPodPathOK(t *testing.T) {
	root := "/workspaces/projets"
	if !AgentPodPathOK(root, root+"/devzone-wt/dz-222") {
		t.Fatal("valid refused")
	}
	for _, bad := range []string{
		"/workspaces/projets", "/workspaces/projets/", root + "/a b", root + "/a;b", root + "/a/../b",
		root + "/a//b", root + "/a/./b", root + "/../x", root + "/a b", "/elsewhere/x",
	} {
		if AgentPodPathOK(root, bad) {
			t.Fatal("bad accepted", bad)
		}
	}
}

// TestAgentPodValidateFolder checks the derived mounts, label and ticket and
// refuses folders without .git, outside the root, with a space or a foreign depot.
func TestAgentPodValidateFolder(t *testing.T) {
	root := t.TempDir()
	folder := fauxWorktree(t, root, "devzone", "dz-222")
	st, ok := AgentPodValidateFolder(folder, root, nil)
	if !ok {
		t.Fatal("valid refused")
	}
	if st.WorktreeSubpath != "devzone-wt/dz-222" || st.WorktreeMountpath != folder {
		t.Fatal("subpath", st)
	}
	if st.GitSubpath != "devzone/.git" || st.GitMountpath != filepath.Join(root, "devzone", ".git") {
		t.Fatal("git", st)
	}
	if st.SessionLabel != "dz-222" || st.Ticket != "222" {
		t.Fatal("label/ticket", st)
	}
	noGit := filepath.Join(root, "dz-no-git")
	os.MkdirAll(noGit, 0o755)
	if _, ok := AgentPodValidateFolder(noGit, root, nil); ok {
		t.Fatal("no .git accepted")
	}
	if _, ok := AgentPodValidateFolder(t.TempDir(), root, nil); ok {
		t.Fatal("outside accepted")
	}
	spaced := filepath.Join(root, "devzone-wt", "dz 222")
	os.MkdirAll(spaced, 0o755)
	os.WriteFile(filepath.Join(spaced, ".git"), []byte("gitdir: x\n"), 0o644)
	if _, ok := AgentPodValidateFolder(spaced, root, nil); ok {
		t.Fatal("space accepted")
	}
	f2 := filepath.Join(root, "devzone-wt", "dz-222")
	os.MkdirAll(f2, 0o755)
	os.WriteFile(filepath.Join(f2, ".git"), []byte("gitdir: /elsewhere/depot/.git/worktrees/dz-222\n"), 0o644)
	if _, ok := AgentPodValidateFolder(f2, root, nil); ok {
		t.Fatal("depot outside accepted")
	}
}

// TestAgentPodName checks that the pod name is lowercase for Kubernetes.
func TestAgentPodName(t *testing.T) {
	n := AgentPodName("/x/Dz-Foo")
	if !strings.HasPrefix(n, "agent-dz-foo-") {
		t.Fatal("lowercase", n)
	}
	other := AgentPodName("/x/Dz-Bar")
	if other == n || !strings.HasPrefix(other, "agent-dz-bar-") {
		t.Fatal("distinct names", n, other)
	}
	if !strings.HasPrefix(AgentPodName(""), "agent-session-") {
		t.Fatal("default base")
	}
}
