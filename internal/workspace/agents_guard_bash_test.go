package workspace

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"testing"
)

// agentsGuardScript is the bash original of the pod agents guard, sourced by
// manage/workspace.sh through workspace-clone.sh.
const agentsGuardScript = "../../manage/scripts/workspace/workspace-clone.sh"

// TestAgentsGuardMatchesBash compares the line and the kubectl arguments of
// the shell guard and of AgentsGuard, with a fake kubectl in the PATH and no
// pod behind it.
func TestAgentsGuardMatchesBash(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("the bash original does not run on Windows")
	}
	if _, err := exec.LookPath("bash"); err != nil {
		t.Skip("bash not found")
	}
	dir := t.TempDir()
	bin := filepath.Join(dir, "bin")
	if err := os.Mkdir(bin, 0o755); err != nil {
		t.Fatal(err)
	}
	kubectl := "#!/usr/bin/env bash\nprintf '%s\\n' \"$*\" >>\"$FAKE_LOG\"\nexit \"${FAKE_STATUS:-0}\"\n"
	if err := os.WriteFile(filepath.Join(bin, "kubectl"), []byte(kubectl), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	path, err := filepath.Abs(agentsGuardScript)
	if err != nil {
		t.Fatal(err)
	}
	for _, status := range []int{0, 1} {
		t.Run("kubectl status "+strconv.Itoa(status), func(t *testing.T) {
			caseDir := filepath.Join(dir, strconv.Itoa(status))
			if err := os.Mkdir(caseDir, 0o755); err != nil {
				t.Fatal(err)
			}
			bashLog := filepath.Join(caseDir, "bash.log")
			goLog := filepath.Join(caseDir, "go.log")
			t.Setenv("FAKE_LOG", bashLog)
			t.Setenv("FAKE_STATUS", strconv.Itoa(status))
			cmd := exec.Command("bash", "-c", `. "$1"; kubectl_flag() { kubectl config get-contexts -o name 2>/dev/null | grep -qx devzone && printf -- '--context devzone'; }; POD=devzone-workspace-0; NAMESPACE=devzone-workspace; workspace_agents_guard`, "_", path)
			cmd.Dir = dir
			want, err := cmd.CombinedOutput()
			if err != nil {
				t.Fatalf("bash failed: %v\n%s", err, want)
			}
			t.Setenv("FAKE_LOG", goLog)
			var out strings.Builder
			AgentsGuard(ExecRunner{}, &out)
			if out.String() != string(want) {
				t.Fatalf("bash %q, Go %q", want, out.String())
			}
			bashCalls, err := os.ReadFile(bashLog)
			if err != nil {
				t.Fatal(err)
			}
			goCalls, err := os.ReadFile(goLog)
			if err != nil {
				t.Fatal(err)
			}
			if string(bashCalls) != string(goCalls) {
				t.Fatalf("bash calls %q, Go calls %q", bashCalls, goCalls)
			}
		})
	}
}
