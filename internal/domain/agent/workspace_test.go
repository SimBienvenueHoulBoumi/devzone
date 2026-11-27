package agent

import (
	"context"
	"strings"
	"testing"

	dzexec "github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
)

// kcFake scripted kubectl for agent_workspace (#431).
type kcFake struct {
	phase     string
	testCode  int
	agentCode int
	catCode   int
	calls     []string
}

func (k *kcFake) Run(ctx context.Context, name string, args []string, opts dzexec.Opts) (dzexec.Result, error) {
	joined := strings.Join(args, " ")
	k.calls = append(k.calls, joined)
	switch {
	case joined == "config get-contexts -o name":
		return dzexec.Result{Stdout: []byte("devzone\n")}, nil
	case strings.Contains(joined, "get pod devzone-workspace-0 "):
		return dzexec.Result{Stdout: []byte(k.phase), Code: 0}, nil
	case strings.Contains(joined, "exec devzone-workspace-0") && strings.Contains(joined, "test -d"):
		return dzexec.Result{Code: k.testCode}, nil
	case strings.Contains(joined, "exec devzone-workspace-0") && strings.Contains(joined, "devzone agent"):
		return dzexec.Result{Code: k.agentCode}, nil
	case strings.Contains(joined, "exec devzone-workspace-0") && strings.Contains(joined, "cat ") && strings.Contains(joined, ".agents/"):
		return dzexec.Result{Stdout: []byte("=== pod session\n"), Code: k.catCode}, nil
	case strings.Contains(joined, " cp "):
		return dzexec.Result{Code: 0}, nil
	}
	return dzexec.Result{Code: 0}, nil
}

func TestWorkspaceAvailable(t *testing.T) {
	t.Setenv("DEVZONE_WORKSPACE", "")
	k := &kcFake{phase: "Running"}
	if !WorkspaceAvailable(context.Background(), k) {
		t.Fatal("not available")
	}
	k2 := &kcFake{phase: "Pending"}
	if WorkspaceAvailable(context.Background(), k2) {
		t.Fatal("available when pending")
	}
	t.Setenv("DEVZONE_WORKSPACE", "kubernetes")
	if WorkspaceAvailable(context.Background(), k) {
		t.Fatal("available in pod")
	}
}

func TestAgentWorkspace(t *testing.T) {
	s := newSandbox(t)
	k := &kcFake{phase: "Running"}
	var out, errOut strings.Builder
	code := AgentWorkspace(context.Background(), k, &out, &errOut, s.proj, s.brief, s.root, "", s.journal())
	if code != 0 {
		t.Fatal("code", code, errOut.String())
	}
	if !strings.Contains(out.String(), "Kubernetes workspace") {
		t.Fatal("no message", out.String())
	}
	if !hasKC(k, "cp "+s.brief+" devzone-workspace-0:/tmp/devzone-agent-projet.md -c workspace") {
		t.Fatal("brief not copied", k.calls)
	}
	if !hasKC(k, "exec devzone-workspace-0 -c workspace -- env DEVZONE_ROOT=/home/vscode/.local/share/devzone") {
		t.Fatal("exec env", k.calls)
	}
	if !hasKC(k, "ulimit -c 0; devzone agent") {
		t.Fatal("core dumps not disabled in the pod", k.calls)
	}
	if !hasKC(k, "/workspaces/projets/projet /tmp/devzone-agent-projet.md") {
		t.Fatal("in-pod args", k.calls)
	}
	if !strings.Contains(readFileString(s.journal()), "pod session") {
		t.Fatal("journal not brought back", readFileString(s.journal()))
	}
	// no local opencode
	if len(modelsLaunched()) != 0 {
		t.Fatal("local launched", modelsLaunched())
	}
}

func TestAgentWorkspaceRelayCode(t *testing.T) {
	s := newSandbox(t)
	k := &kcFake{phase: "Running", agentCode: 7}
	var out, errOut strings.Builder
	if code := AgentWorkspace(context.Background(), k, &out, &errOut, s.proj, s.brief, s.root, "", s.journal()); code != 7 {
		t.Fatal("code", code)
	}
}

func TestAgentWorkspaceProjectAbsent(t *testing.T) {
	s := newSandbox(t)
	k := &kcFake{phase: "Running", testCode: 1}
	var out, errOut strings.Builder
	if code := AgentWorkspace(context.Background(), k, &out, &errOut, s.proj, s.brief, s.root, "", s.journal()); code != 2 {
		t.Fatal("code", code)
	}
	if !strings.Contains(errOut.String(), "copy-to") {
		t.Fatal("no copy-to", errOut.String())
	}
	if hasKC(k, " cp ") || hasKC(k, "devzone agent") {
		t.Fatal("launched", k.calls)
	}
}

func TestAgentWorkspacePodPath(t *testing.T) {
	s := newSandbox(t)
	k := &kcFake{phase: "Running"}
	var out, errOut strings.Builder
	// /workspaces/projets/... absent here -> folder of the pod
	code := AgentWorkspace(context.Background(), k, &out, &errOut, "/workspaces/projets/devzone-wt/dz-4242", s.brief, s.root, "", s.root+"/workspace/.agents/dz-4242.log")
	if code != 0 {
		t.Fatal("code", code, errOut.String())
	}
	if !hasKC(k, "test -d /workspaces/projets/devzone-wt/dz-4242") {
		t.Fatal("test -d", k.calls)
	}
	if !hasKC(k, "cp "+s.brief+" devzone-workspace-0:/tmp/devzone-agent-dz-4242.md") {
		t.Fatal("cp", k.calls)
	}
	if !hasKC(k, "_ /workspaces/projets/devzone-wt/dz-4242 /tmp/devzone-agent-dz-4242.md") {
		t.Fatal("args", k.calls)
	}
}

func hasKC(k *kcFake, substr string) bool {
	for _, c := range k.calls {
		if strings.Contains(c, substr) {
			return true
		}
	}
	return false
}
