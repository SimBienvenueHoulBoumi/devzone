package podcmd

import (
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"testing"
)

// launcherWithoutBinary copies the launcher and stubs its shell libraries, so a
// command can reach the case without a pod binary or a full devzone checkout.
func launcherWithoutBinary(t *testing.T) string {
	t.Helper()
	dir := launcherSetup(t, false)
	for _, name := range []string{
		"help.sh", "cluster.sh", "state-gitops.sh", "devzone-modules.sh",
		"devzone-services.sh", "devzone-cluster.sh",
		"devzone-repair.sh", "devzone-platform.sh", "devzone-version.sh", "devzone-status.sh",
	} {
		p := filepath.Join(dir, name)
		os.MkdirAll(filepath.Dir(p), 0o755)
		if err := os.WriteFile(p, []byte("devzone_aide() { :; }\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

// TestLauncherAgentWithoutPodBinary checks that `devzone agent` without the pod
// binary refuses like the other ported commands instead of calling a script.
func TestLauncherAgentWithoutPodBinary(t *testing.T) {
	if runtime.GOOS == "windows" || (runtime.GOARCH != "amd64" && runtime.GOARCH != "arm64") {
		t.Skip()
	}
	dir := launcherWithoutBinary(t)
	for _, name := range []string{"agent", "postgres", "mysql", "gitlab", "test-gitlab", "argocd"} {
		out, code := runLauncher(t, dir, nil, name, "state")
		want := "devzone " + name + ": Go binary of the pod unavailable (.devcontainer/bin)\n"
		if code != 1 || out != want {
			t.Fatalf("%s: code = %d, out = %q, want 1 and %q", name, code, out, want)
		}
	}
}

// TestCIWorkflowBatsFilesExist checks that every bats file named by the CI
// workflow is still in the tree: the agent tests were ported to Go (#878).
func TestCIWorkflowBatsFilesExist(t *testing.T) {
	data, err := os.ReadFile("../../.github/workflows/fonctionnel.yml")
	if err != nil {
		t.Fatal(err)
	}
	re := regexp.MustCompile(`manage/test/[A-Za-z0-9_.-]+\.bats`)
	for _, name := range re.FindAllString(string(data), -1) {
		if _, err := os.Stat(filepath.Join("..", "..", name)); err != nil {
			t.Errorf("CI cites a missing bats file: %s", name)
		}
	}
}

// TestDevcontainerCommentNamesGoAgent checks that the state volume comment
// names the Go command, not the removed agent script (#878).
func TestDevcontainerCommentNamesGoAgent(t *testing.T) {
	data, err := os.ReadFile("../../.devcontainer/devcontainer.json")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), "agent.sh writes it") {
		t.Fatal("comment still cites the removed agent script")
	}
	if !strings.Contains(string(data), "path where devzone agent writes it") {
		t.Fatal("comment does not name devzone agent")
	}
}

// caseArmAlternatives returns the alternatives of the shell case arm carrying
// name. Continuation lines are joined first, and the arm stops at its closing
// parenthesis, so callers can check membership without depending on neighbours.
func caseArmAlternatives(t *testing.T, data, name string) map[string]bool {
	t.Helper()
	lines := strings.Split(data, "\n")
	for i, line := range lines {
		if !strings.Contains(line, name) || !strings.Contains(line, "|") {
			continue
		}
		arm := strings.TrimSpace(line)
		for strings.HasSuffix(arm, "\\") && i+1 < len(lines) {
			arm = strings.TrimSuffix(arm, "\\") + " " + strings.TrimSpace(lines[i+1])
			i++
		}
		if end := strings.Index(arm, ")"); end >= 0 {
			arm = arm[:end]
		}
		alts := make(map[string]bool)
		for _, alt := range strings.Split(arm, "|") {
			alts[strings.TrimSpace(alt)] = true
		}
		if alts[name] {
			return alts
		}
	}
	return nil
}

// TestAgentCommandListsKeepAgent checks that both launchers and the pod help
// still declare the Go commands, whatever their neighbours, so a machine
// without the pod binary cannot reach a removed script (#878).
func TestAgentCommandListsKeepAgent(t *testing.T) {
	for _, tc := range []struct {
		file  string
		names []string
	}{
		{"../../.devcontainer/devzone", []string{"agent", "postgres", "mysql", "gitlab", "test-gitlab", "catalog", "catalog-watcher"}},
		{"../../manage/devzone", []string{"agent", "catalog", "catalog-watcher", "ai", "apply"}},
	} {
		data, err := os.ReadFile(tc.file)
		if err != nil {
			t.Fatal(err)
		}
		alts := caseArmAlternatives(t, string(data), "agent")
		if alts == nil {
			t.Fatalf("%s has no case arm for agent", tc.file)
		}
		for _, name := range tc.names {
			if !alts[name] {
				t.Errorf("%s case arm misses %q: %v", tc.file, name, alts)
			}
		}
	}
	data, err := os.ReadFile("../../.devcontainer/help.sh")
	if err != nil {
		t.Fatal(err)
	}
	for _, text := range []string{"devzone agent <folder> <instructions>", "devzone catalog "} {
		if !strings.Contains(string(data), text) {
			t.Errorf(".devcontainer/help.sh misses %q", text)
		}
	}
}
