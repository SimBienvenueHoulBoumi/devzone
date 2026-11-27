package podcmd

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// statusFixture creates a disposable instance and programs every command of
// the summary, so no test reaches a real tool, service or network.
func statusFixture(t *testing.T) (root, script, stateFile string, r stubRunner) {
	t.Helper()
	root, code, stateFile := jsonFixture(t)
	script = filepath.Join(code, "devzone")
	r = stubRunner{t: t, responses: map[string]exec.Result{}}
	r.program(nil, 0, "", "git", "config", "--get", "user.name")
	r.program(nil, 0, "", "git", "config", "--get", "user.email")
	r.program(nil, 1, "not logged in\n", "gh", "auth", "status")
	r.program(nil, 0, "", "bash", filepath.Join(root, "manage", "scripts", "ci", "versions.sh"), "--installees")
	r.program(nil, 0, "", "git", "-C", filepath.Join(root, "workspace", "repo"), "worktree", "list", "--porcelain")
	r.program(nil, 0, "", script, "kube", "saved")
	r.program(nil, 0, "", script, "cluster", "clean", "--quiet")
	r.program(nil, 0, "", "kind", "get", "clusters")
	r.program(nil, 0, "", "kubectl", "config", "current-context")
	r.program(nil, 0, "", "kubectl", "auth", "can-i", "--as=system:serviceaccount:default:default", "get", "secrets", "-n", "devzone-postgres")
	r.program([]string{"DEVZONE_STATE=" + stateFile}, 0, "none\n", "devzone", "port", "resume")
	return root, script, stateFile, r
}

// runStatusText runs the registered status command with a stub runner.
func runStatusText(t *testing.T, r stubRunner, args ...string) string {
	t.Helper()
	return runStatusWithRunner(t, r, args...)
}

// runStatusWithRunner runs the registered status command with a supplied runner.
func runStatusWithRunner(t *testing.T, runner exec.Runner, args ...string) string {
	t.Helper()
	var out, errOut bytes.Buffer
	ctx := &cli.Context{Out: &out, Err: &errOut, Runner: runner}
	code, ok := Registry.Run(append([]string{"status"}, args...), ctx)
	if !ok || code != 0 || errOut.Len() > 0 {
		t.Fatalf("handled = %v, code = %d, errOut = %q", ok, code, errOut.String())
	}
	return out.String()
}

// contains checks that each expected fragment appears in the status output.
func contains(t *testing.T, out string, want ...string) {
	t.Helper()
	for _, fragment := range want {
		if !strings.Contains(out, fragment) {
			t.Errorf("status misses %q:\n%s", fragment, out)
		}
	}
}

// TestStatusDefaultAndAliases checks the startup summary and that the launcher
// names status, modules and the empty command all reach the Go handler.
func TestStatusDefaultAndAliases(t *testing.T) {
	_, _, _, r := statusFixture(t)
	for _, name := range []string{"status", "modules", ""} {
		if _, ok := Registry.Lookup(name); !ok {
			t.Fatalf("%q is not registered", name)
		}
	}
	out := runStatusText(t, r)
	contains(t, out,
		"devzone: state (devzone to show it again)",
		"  ✖ git identity    needed to commit",
		"  ✔ platform       github",
		"  ○ GitHub          optional",
		"  ✔ tools          pinned versions",
		"  ○ module ai", "AI assistants: Claude Code, opencode: devzone enable ai",
		"  ○ module kubernetes", "connection to the host cluster and metrics-server at startup: devzone enable kubernetes",
		"  ○ ports to the workstation none",
	)
	var emptyOut, emptyErr bytes.Buffer
	ctx := &cli.Context{Out: &emptyOut, Err: &emptyErr, Runner: r}
	if code, ok := Registry.Run([]string{""}, ctx); !ok || code != 0 || emptyOut.String() != out {
		t.Fatalf("empty command: handled %v, code %d, output %q", ok, code, emptyOut.String())
	}
}

// TestStatusIdentityAndGitHub checks the identity and GitHub states of the
// summary, including the missing workflow scope.
func TestStatusIdentityAndGitHub(t *testing.T) {
	t.Run("identity present", func(t *testing.T) {
		_, _, _, r := statusFixture(t)
		r.program(nil, 0, "Test User\n", "git", "config", "--get", "user.name")
		r.program(nil, 0, "t@example.invalid\n", "git", "config", "--get", "user.email")
		contains(t, runStatusText(t, r), "  ✔ git identity    Test User <t@example.invalid>")
	})
	for _, tc := range []struct {
		name, answer, want string
		code               int
	}{
		{"without workflow", "Token scopes: 'gist', 'repo'\n", "  ⚠ GitHub          connected, without workflow permission", 0},
		{"with workflow", "Token scopes: 'gist', 'workflow'\n", "  ✔ GitHub          connected", 0},
		{"absent", "not logged in\n", "  ○ GitHub          optional", 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, _, _, r := statusFixture(t)
			r.program(nil, tc.code, tc.answer, "gh", "auth", "status")
			contains(t, runStatusText(t, r), tc.want)
		})
	}
}

// TestStatusToolsAndWorktrees checks the outdated-tool warning and the absent
// worktree warning, plus their quiet cases.
func TestStatusToolsAndWorktrees(t *testing.T) {
	t.Run("outdated tool", func(t *testing.T) {
		root, _, _, r := statusFixture(t)
		r.program(nil, 0, "repowarden 4.9.2 5.0.0\n", "bash", filepath.Join(root, "manage", "scripts", "ci", "versions.sh"), "--installees")
		contains(t, runStatusText(t, r), "  ⚠ tools          repowarden 5.0.0 installed, 4.9.2 pinned: devzone apply")
	})
	t.Run("missing worktree", func(t *testing.T) {
		root, _, _, r := statusFixture(t)
		absent := filepath.Join(root, "wt-absent")
		r.program(nil, 0, "worktree "+absent+"\n", "git", "-C", filepath.Join(root, "workspace", "repo"), "worktree", "list", "--porcelain")
		contains(t, runStatusText(t, r), "  ⚠ worktree        "+absent+" absent here", "never git worktree prune")
	})
	t.Run("present worktree", func(t *testing.T) {
		root, _, _, r := statusFixture(t)
		present := filepath.Join(root, "wt-present")
		if err := os.MkdirAll(present, 0o755); err != nil {
			t.Fatal(err)
		}
		r.program(nil, 0, "worktree "+present+"\n", "git", "-C", filepath.Join(root, "workspace", "repo"), "worktree", "list", "--porcelain")
		if strings.Contains(runStatusText(t, r), "  ⚠ worktree") {
			t.Fatal("a present worktree must not be reported")
		}
	})
}

// TestStatusModules checks active, failed, detailed and pod service lines, plus
// the Argo CD hold line.
func TestStatusModules(t *testing.T) {
	t.Run("active ai", func(t *testing.T) {
		_, _, stateFile, r := statusFixture(t)
		writeJSONFile(t, stateFile, "ai=on\n")
		contains(t, runStatusText(t, r), "  ✔ module ai", "active: AI assistants: Claude Code, opencode")
	})
	t.Run("failed gitlab", func(t *testing.T) {
		_, _, stateFile, r := statusFixture(t)
		writeJSONFile(t, stateFile, "gitlab=on\n")
		writeJSONFile(t, stateFile+"-failed-gitlab", "helm failed")
		contains(t, runStatusText(t, r), "  ✖ module gitlab", "failed: incomplete install (helm failed): devzone apply")
	})
	t.Run("detailed gitlab", func(t *testing.T) {
		_, script, stateFile, r := statusFixture(t)
		writeJSONFile(t, stateFile, "gitlab=on\n")
		r.program(nil, 0, "ready on services cluster\n", script, "gitlab", "status")
		contains(t, runStatusText(t, r), "  ✔ module gitlab", "ready on services cluster")
	})
	t.Run("held by argocd", func(t *testing.T) {
		_, script, stateFile, r := statusFixture(t)
		writeJSONFile(t, stateFile, "mysql=on\nargocd=on\n")
		r.program(nil, 0, "", script, "argocd", "status")
		r.program(nil, 0, "", script, "mysql", "status")
		contains(t, runStatusText(t, r), "                    tenu par Argo CD : Application devzone-mysql")
	})
	t.Run("pod service", func(t *testing.T) {
		_, script, stateFile, r := statusFixture(t)
		t.Setenv("DEVZONE_WORKSPACE", "kubernetes")
		writeJSONFile(t, stateFile, "gitlab=on\n")
		r.program(nil, 0, "", "getent", "hosts", "gitlab-webservice-default.devzone-gitlab.svc")
		r.program(nil, 1, "", "getent", "hosts", "postgres.devzone-postgres.svc")
		r.program(nil, 1, "", "getent", "hosts", "argocd-server.devzone-argocd.svc")
		r.program([]string{"DEVZONE_STATE=" + stateFile}, 0, "  ○ argocd          GitOps repository: https://example.invalid/repo\n", script, "state", "gitops-line")
		contains(t, runStatusText(t, r), "  ✔ module gitlab", "active: test GitLab in the services cluster (gitlab-webservice-default.devzone-gitlab.svc)")
		r.program(nil, 1, "", "getent", "hosts", "gitlab-webservice-default.devzone-gitlab.svc")
		contains(t, runStatusText(t, r), "  ⚠ module gitlab", "not in the cluster")
	})
}
