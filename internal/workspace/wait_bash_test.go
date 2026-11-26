package workspace

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// waitScript is the bash original of the pod wait, sourced by workspace.sh.
const waitScript = "../../manage/scripts/workspace/workspace-wait.sh"

// waitBashHarness runs wait_for_pod with a fake kubectl that replays one
// scenario, and runs the Go wait with the same fake. It is skipped on Windows
// and without bash: the original is a shell script.
type waitBashHarness struct {
	t    *testing.T
	dir  string
	bin  string
	bash string
}

// newWaitBashHarness prepares the fake kubectl in a temporary bin folder.
func newWaitBashHarness(t *testing.T) *waitBashHarness {
	t.Helper()
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
	kubectl := `#!/usr/bin/env bash
case "$*" in
*"config get-contexts"*) exit 0 ;;
*"get statefulset"*) printf '%s' "$FAKE_TARGET" ;;
*"get pod devzone-workspace-0"*controller-revision-hash*) printf '%s' "$FAKE_PODREV" ;;
*"get pod devzone-workspace-0"*) printf '%s' "$FAKE_STATE" ;;
*"get events"*) printf '%s' "$FAKE_EVENTS" ;;
*"get nodes"*) printf '%s' "$FAKE_ARCH" ;;
esac
exit 0
`
	if err := os.WriteFile(filepath.Join(bin, "kubectl"), []byte(kubectl), 0o755); err != nil {
		t.Fatal(err)
	}
	path, err := filepath.Abs(waitScript)
	if err != nil {
		t.Fatal(err)
	}
	return &waitBashHarness{t: t, dir: dir, bin: bin, bash: path}
}

// scenario sets the fake outputs and the PATH for both implementations.
func (h *waitBashHarness) scenario(values map[string]string) {
	h.t.Helper()
	for key, value := range values {
		h.t.Setenv(key, value)
	}
	h.t.Setenv("DEVZONE_WORKSPACE_WAIT", "5")
	h.t.Setenv("DEVZONE_WORKSPACE_STEP", "1")
	h.t.Setenv("PATH", h.bin+string(os.PathListSeparator)+os.Getenv("PATH"))
}

// shell runs the bash function and returns its combined output and status.
func (h *waitBashHarness) shell(image string) (string, int) {
	h.t.Helper()
	cmd := exec.Command("bash", "-c",
		`. "$1"; kubectl_flag() { :; }; workspace_undeploy() { :; }; wait_for_pod "$2"`,
		"_", h.bash, image)
	cmd.Dir = h.dir
	out, err := cmd.CombinedOutput()
	status := 0
	if err != nil {
		exitErr, ok := err.(*exec.ExitError)
		if !ok {
			h.t.Fatalf("cannot run bash: %v", err)
		}
		status = exitErr.ExitCode()
	}
	return string(out), status
}

// goWait runs the Go wait with the same fake kubectl.
func (h *waitBashHarness) goWait(image string) (string, int) {
	h.t.Helper()
	var out, errOut bytes.Buffer
	status := WaitForPod(ExecRunner{}, image, &out, &errOut, func() int { return 0 })
	return out.String() + errOut.String(), status
}

// TestWaitMatchesBash compares the output and status of wait_for_pod and
// WaitForPod on the scenarios a user can meet after a helm upgrade.
func TestWaitMatchesBash(t *testing.T) {
	for _, tc := range []struct {
		name   string
		values map[string]string
	}{
		{"running", map[string]string{"FAKE_TARGET": "rev1", "FAKE_PODREV": "rev1", "FAKE_STATE": "Running"}},
		{"pull failure", map[string]string{"FAKE_TARGET": "rev1", "FAKE_PODREV": "rev1",
			"FAKE_STATE": "Pending ImagePullBackOff", "FAKE_EVENTS": "manifest invalid"}},
		{"no build", map[string]string{"FAKE_TARGET": "rev1", "FAKE_PODREV": "rev1",
			"FAKE_STATE": "Init:ImagePullBackOff", "FAKE_EVENTS": "no match for platform", "FAKE_ARCH": "arm64"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			h := newWaitBashHarness(t)
			h.scenario(tc.values)
			want, wantStatus := h.shell("repo:1")
			got, gotStatus := h.goWait("repo:1")
			if strings.TrimSpace(got) != strings.TrimSpace(want) || gotStatus != wantStatus {
				t.Fatalf("bash (%d) %q, Go (%d) %q", wantStatus, want, gotStatus, got)
			}
		})
	}
}
