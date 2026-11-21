package workspace

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// bashScriptsFiles are the bash files that hold the scripts run in the pod, as
// seen from this package
var bashScriptsFiles = []string{
	"../../manage/scripts/workspace/workspace-copies.sh",
	"../../manage/scripts/workspace/workspace-clone.sh",
}

// bashPodScript returns the script that the bash function function sends to the
// pod: the lines between the first "cat <<'POD'" after its definition and the
// closing "POD", in whichever of bashScriptsFiles defines the function. Both
// copies (bash and Go) must hold the same text.
func bashPodScript(t *testing.T, function string) string {
	t.Helper()
	for _, file := range bashScriptsFiles {
		if script, ok := heredocOf(t, file, function); ok {
			return script
		}
	}
	t.Fatalf("function %s not found in %s", function, strings.Join(bashScriptsFiles, ", "))
	return ""
}

// heredocOf returns the heredoc of the function defined in file, and false when
// the file does not define it
func heredocOf(t *testing.T, file, function string) (string, bool) {
	t.Helper()
	data, err := os.ReadFile(filepath.FromSlash(file))
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(string(data), "\n")
	start := -1
	for i, line := range lines {
		if line == function+"() {" {
			start = i
			break
		}
	}
	if start < 0 {
		return "", false
	}
	var script []string
	inHeredoc := false
	for _, line := range lines[start:] {
		if !inHeredoc {
			inHeredoc = strings.TrimSpace(line) == "cat <<'POD'"
			continue
		}
		if line == "POD" {
			return strings.Join(script, "\n") + "\n", true
		}
		script = append(script, line)
	}
	t.Fatalf("heredoc of %s not closed in %s", function, file)
	return "", false
}

// TestLegacyScriptMatchesBash checks that podScript (legacy.go) is the script of
// workspace_legacy_pod_script in manage/scripts/workspace/workspace-copies.sh
func TestLegacyScriptMatchesBash(t *testing.T) {
	if want := bashPodScript(t, "workspace_legacy_pod_script"); podScript != want {
		t.Fatalf("podScript differs from the bash script:\n%s\nwant:\n%s", podScript, want)
	}
}

// TestCopyGuardScriptMatchesBash checks that copyGuardScript (copy_guard.go) is
// the script of workspace_copy_pod_script in manage/scripts/workspace/workspace-copies.sh
func TestCopyGuardScriptMatchesBash(t *testing.T) {
	if want := bashPodScript(t, "workspace_copy_pod_script"); copyGuardScript != want {
		t.Fatalf("copyGuardScript differs from the bash script:\n%s\nwant:\n%s", copyGuardScript, want)
	}
}

// TestCloneScriptMatchesBash checks that cloneScript (clone_script.go) is the
// script of workspace_clone_pod_script in manage/scripts/workspace/workspace-clone.sh
func TestCloneScriptMatchesBash(t *testing.T) {
	if want := bashPodScript(t, "workspace_clone_pod_script"); cloneScript != want {
		t.Fatalf("cloneScript differs from the bash script:\n%s\nwant:\n%s", cloneScript, want)
	}
}
