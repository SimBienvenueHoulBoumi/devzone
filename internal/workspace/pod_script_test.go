package workspace

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// bashScriptsFile is the bash file that holds the scripts run in the pod, as
// seen from this package
const bashScriptsFile = "../../manage/scripts/workspace-copies.sh"

// bashPodScript returns the script that the bash function function sends to the
// pod: the lines between the first "cat <<'POD'" after its definition and the
// closing "POD". Both copies (bash and Go) must hold the same text.
func bashPodScript(t *testing.T, function string) string {
	t.Helper()
	data, err := os.ReadFile(filepath.FromSlash(bashScriptsFile))
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
		t.Fatalf("function %s not found in %s", function, bashScriptsFile)
	}
	var script []string
	inHeredoc := false
	for _, line := range lines[start:] {
		if !inHeredoc {
			inHeredoc = strings.TrimSpace(line) == "cat <<'POD'"
			continue
		}
		if line == "POD" {
			return strings.Join(script, "\n") + "\n"
		}
		script = append(script, line)
	}
	t.Fatalf("heredoc of %s not closed in %s", function, bashScriptsFile)
	return ""
}

// TestLegacyScriptMatchesBash checks that podScript (legacy.go) is the script of
// workspace_legacy_pod_script in manage/scripts/workspace-copies.sh
func TestLegacyScriptMatchesBash(t *testing.T) {
	if want := bashPodScript(t, "workspace_legacy_pod_script"); podScript != want {
		t.Fatalf("podScript differs from the bash script:\n%s\nwant:\n%s", podScript, want)
	}
}

// TestCopyGuardScriptMatchesBash checks that copyGuardScript (copy_guard.go) is
// the script of workspace_copy_pod_script in manage/scripts/workspace-copies.sh
func TestCopyGuardScriptMatchesBash(t *testing.T) {
	if want := bashPodScript(t, "workspace_copy_pod_script"); copyGuardScript != want {
		t.Fatalf("copyGuardScript differs from the bash script:\n%s\nwant:\n%s", copyGuardScript, want)
	}
}
