package podcmd

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/testkit"
)

// launcherSetup creates a temp copy of the devzone launcher and, when withBinary is true, a fake Go pod binary that handles "ported" and "build".
func launcherSetup(t *testing.T, withBinary bool) string {
	t.Helper()
	dir := t.TempDir()

	src, err := os.ReadFile("../../.devcontainer/devzone")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "devzone"), src, 0o755); err != nil {
		t.Fatal(err)
	}

	if withBinary {
		binDir := filepath.Join(dir, "bin")
		if err := os.MkdirAll(binDir, 0o755); err != nil {
			t.Fatal(err)
		}
		binary := "#!/usr/bin/env bash\nif [ \"$1\" = handles ]; then case \"$2\" in ported|build) exit 0 ;; *) exit 1 ;; esac; fi\necho \"go:$*\"\necho \"script:$DEVZONE_POD_SCRIPT\"\nexit 0\n"
		binPath := filepath.Join(binDir, "devzone-pod-linux-"+runtime.GOARCH)
		if err := os.WriteFile(binPath, []byte(binary), 0o755); err != nil {
			t.Fatal(err)
		}
	}

	return dir
}

// runLauncher runs the copied launcher with the given environment and arguments.
func runLauncher(t *testing.T, dir string, env []string, args ...string) (string, int) {
	t.Helper()
	cmd := exec.Command("bash", append([]string{filepath.Join(dir, "devzone")}, args...)...)
	// Drop the pod binary and script inherited from a workspace session, so the
	// copied launcher picks the fake binary or refuses, and explicit env wins.
	base := testkit.FilterEnv(testkit.CommandEnv(), "DEVZONE_HOST_BIN", "DEVZONE_POD_SCRIPT")
	cmd.Env = append(base, env...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		exitErr, ok := err.(*exec.ExitError)
		if !ok {
			t.Fatalf("run launcher: %v", err)
		}
		return string(out), exitErr.ExitCode()
	}
	return string(out), 0
}

// TestLauncherRunsPortedCommandInGo checks that a ported command is executed by the Go binary.
func TestLauncherRunsPortedCommandInGo(t *testing.T) {
	if runtime.GOOS == "windows" || (runtime.GOARCH != "amd64" && runtime.GOARCH != "arm64") {
		t.Skip()
	}
	dir := launcherSetup(t, true)
	out, code := runLauncher(t, dir, nil, "ported", "a", "b")
	if code != 0 {
		t.Fatalf("code = %d, want 0", code)
	}
	if !strings.Contains(out, "go:ported a b") {
		t.Fatalf("out = %q, want it to contain %q", out, "go:ported a b")
	}
}

// TestLauncherRoutesAgentToGo checks that devzone agent reaches the Go binary and never the removed shell script (Ticket #878).
func TestLauncherRoutesAgentToGo(t *testing.T) {
	if runtime.GOOS == "windows" || (runtime.GOARCH != "amd64" && runtime.GOARCH != "arm64") {
		t.Skip()
	}
	dir := launcherSetup(t, true)
	binPath := filepath.Join(dir, "bin", "devzone-pod-linux-"+runtime.GOARCH)
	binary := "#!/usr/bin/env bash\nif [ \"$1\" = handles ]; then [ \"$2\" = agent ] && exit 0; exit 1; fi\necho \"go:$*\"\nexit 0\n"
	if err := os.WriteFile(binPath, []byte(binary), 0o755); err != nil {
		t.Fatal(err)
	}
	out, code := runLauncher(t, dir, nil, "agent", "state")
	if code != 0 || !strings.Contains(out, "go:agent state") {
		t.Fatalf("code = %d, out = %q, want 0 and go:agent state", code, out)
	}
}

// TestLauncherUsesHostBinFromEnvironment checks that a Go binary built outside
// the image is used by the launcher when DEVZONE_HOST_BIN names it.
func TestLauncherUsesHostBinFromEnvironment(t *testing.T) {
	if runtime.GOOS == "windows" || (runtime.GOARCH != "amd64" && runtime.GOARCH != "arm64") {
		t.Skip()
	}
	dir := launcherSetup(t, false)
	bin := filepath.Join(dir, "devzone-go")
	binary := "#!/usr/bin/env bash\nif [ \"$1\" = handles ]; then [ \"$2\" = help ] && exit 0; exit 1; fi\necho \"go:$*\"\nexit 0\n"
	if err := os.WriteFile(bin, []byte(binary), 0o755); err != nil {
		t.Fatal(err)
	}
	out, code := runLauncher(t, dir, []string{"DEVZONE_HOST_BIN=" + bin}, "help")
	if code != 0 || !strings.Contains(out, "go:help") {
		t.Fatalf("code = %d, out = %q, want 0 and go:help", code, out)
	}
}

// TestLauncherPassesItsOwnShellToGo checks that the Go binary is told which shell to
// delegate back to: the launcher of this devzone folder, not the copy installed in the
// image (#857: a command ported in part, like cluster clean, sends the rest of cluster
// back to the shell).
func TestLauncherPassesItsOwnShellToGo(t *testing.T) {
	if runtime.GOOS == "windows" || (runtime.GOARCH != "amd64" && runtime.GOARCH != "arm64") {
		t.Skip()
	}
	dir := launcherSetup(t, true)
	out, code := runLauncher(t, dir, []string{"DEVZONE_POD_SCRIPT="}, "ported")
	if code != 0 {
		t.Fatalf("code = %d, want 0", code)
	}
	want := "script:" + filepath.Join(dir, "devzone")
	if !strings.Contains(out, want) {
		t.Fatalf("out = %q, want it to contain %q", out, want)
	}
}

// TestLauncherBuildUsesGoBinary checks that the pod binary runs build, with all arguments.
func TestLauncherBuildUsesGoBinary(t *testing.T) {
	if runtime.GOOS == "windows" || (runtime.GOARCH != "amd64" && runtime.GOARCH != "arm64") {
		t.Skip()
	}
	dir := launcherSetup(t, true)
	out, code := runLauncher(t, dir, nil, "build", "folder")
	if code != 0 || !strings.Contains(out, "go:build folder") {
		t.Fatalf("code = %d, out = %q, want 0 and go:build folder", code, out)
	}
}

// TestLauncherBuildWithoutBinaryRefuses checks that build has no shell fallback: without the pod binary the launcher reports Go as unavailable.
func TestLauncherBuildWithoutBinaryRefuses(t *testing.T) {
	if runtime.GOOS == "windows" || (runtime.GOARCH != "amd64" && runtime.GOARCH != "arm64") {
		t.Skip()
	}
	dir := launcherSetup(t, false)
	out, code := runLauncher(t, dir, nil, "build")
	if code != 1 || out != "devzone build: Go binary of the pod unavailable (.devcontainer/bin)\n" {
		t.Fatalf("code = %d, out = %q, want 1 and the Go-only message", code, out)
	}
}

// TestLauncherBuildIgnoresGoSwitches checks that the Go switches cannot send build to a shell fallback.
func TestLauncherBuildIgnoresGoSwitches(t *testing.T) {
	if runtime.GOOS == "windows" || (runtime.GOARCH != "amd64" && runtime.GOARCH != "arm64") {
		t.Skip()
	}
	dir := launcherSetup(t, true)
	want := "devzone build: Go binary of the pod unavailable (.devcontainer/bin)\n"
	for _, env := range [][]string{{"DEVZONE_NO_GO=1"}, {"DEVZONE_FROM_GO=1"}} {
		out, code := runLauncher(t, dir, env, "build")
		if code != 1 || out != want {
			t.Fatalf("%v: code = %d, out = %q, want 1 and %q", env, code, out, want)
		}
	}
}
