package podcmd

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// launcherSetup creates a temp copy of the devzone launcher and, when withBinary is true, a fake Go pod binary that handles only "ported".
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
	if err := os.WriteFile(filepath.Join(dir, "devzone-platform.sh"), []byte("echo SHELL-PATH-REACHED\nexit 42\n"), 0o755); err != nil {
		t.Fatal(err)
	}

	if withBinary {
		binDir := filepath.Join(dir, "bin")
		if err := os.MkdirAll(binDir, 0o755); err != nil {
			t.Fatal(err)
		}
		binary := "#!/usr/bin/env bash\nif [ \"$1\" = handles ]; then [ \"$2\" = ported ] && exit 0; exit 1; fi\necho \"go:$*\"\necho \"script:$DEVZONE_POD_SCRIPT\"\nexit 0\n"
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
	cmd.Env = append(os.Environ(), env...)
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
	if strings.Contains(out, "SHELL-PATH-REACHED") {
		t.Fatalf("out = %q, must not contain %q", out, "SHELL-PATH-REACHED")
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
	if strings.Contains(out, "SHELL-PATH-REACHED") {
		t.Fatalf("out = %q, must not contain %q", out, "SHELL-PATH-REACHED")
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
	if strings.Contains(out, "SHELL-PATH-REACHED") {
		t.Fatalf("out = %q, must not contain the shell stub", out)
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

// TestLauncherKeepsShellForUnportedCommand checks that an unported command stays in the shell.
func TestLauncherKeepsShellForUnportedCommand(t *testing.T) {
	if runtime.GOOS == "windows" || (runtime.GOARCH != "amd64" && runtime.GOARCH != "arm64") {
		t.Skip()
	}
	dir := launcherSetup(t, true)
	out, code := runLauncher(t, dir, nil, "other")
	if code != 42 {
		t.Fatalf("code = %d, want 42", code)
	}
	if !strings.Contains(out, "SHELL-PATH-REACHED") {
		t.Fatalf("out = %q, want it to contain %q", out, "SHELL-PATH-REACHED")
	}
}

// TestLauncherNoGoForcesShell checks that DEVZONE_NO_GO=1 forces the shell path.
func TestLauncherNoGoForcesShell(t *testing.T) {
	if runtime.GOOS == "windows" || (runtime.GOARCH != "amd64" && runtime.GOARCH != "arm64") {
		t.Skip()
	}
	dir := launcherSetup(t, true)
	out, code := runLauncher(t, dir, []string{"DEVZONE_NO_GO=1"}, "ported")
	if code != 42 {
		t.Fatalf("code = %d, want 42", code)
	}
	if !strings.Contains(out, "SHELL-PATH-REACHED") {
		t.Fatalf("out = %q, want it to contain %q", out, "SHELL-PATH-REACHED")
	}
}

// TestLauncherFromGoAvoidsLoop checks that DEVZONE_FROM_GO=1 avoids re-entering Go.
func TestLauncherFromGoAvoidsLoop(t *testing.T) {
	if runtime.GOOS == "windows" || (runtime.GOARCH != "amd64" && runtime.GOARCH != "arm64") {
		t.Skip()
	}
	dir := launcherSetup(t, true)
	out, code := runLauncher(t, dir, []string{"DEVZONE_FROM_GO=1"}, "ported")
	if code != 42 {
		t.Fatalf("code = %d, want 42", code)
	}
	if !strings.Contains(out, "SHELL-PATH-REACHED") {
		t.Fatalf("out = %q, want it to contain %q", out, "SHELL-PATH-REACHED")
	}
}

// TestLauncherWithoutBinaryUsesShell checks that a missing binary falls back to the shell.
func TestLauncherWithoutBinaryUsesShell(t *testing.T) {
	if runtime.GOOS == "windows" || (runtime.GOARCH != "amd64" && runtime.GOARCH != "arm64") {
		t.Skip()
	}
	dir := launcherSetup(t, false)
	out, code := runLauncher(t, dir, nil, "ported")
	if code != 42 {
		t.Fatalf("code = %d, want 42", code)
	}
	if !strings.Contains(out, "SHELL-PATH-REACHED") {
		t.Fatalf("out = %q, want it to contain %q", out, "SHELL-PATH-REACHED")
	}
}

// TestLauncherFromGoNotInherited checks that a command run by the shell path does
// not inherit DEVZONE_FROM_GO: its own devzone calls must reach Go again.
func TestLauncherFromGoNotInherited(t *testing.T) {
	if runtime.GOOS == "windows" || (runtime.GOARCH != "amd64" && runtime.GOARCH != "arm64") {
		t.Skip()
	}
	dir := launcherSetup(t, true)
	help := "printf 'from=%s\\n' \"${DEVZONE_FROM_GO-unset}\"; exit 42\n"
	if err := os.WriteFile(filepath.Join(dir, "devzone-platform.sh"), []byte(help), 0o644); err != nil {
		t.Fatal(err)
	}
	out, code := runLauncher(t, dir, []string{"DEVZONE_FROM_GO=1"}, "ported")
	if code != 42 || !strings.Contains(out, "from=unset") {
		t.Fatalf("code = %d, out = %q, want 42 and from=unset", code, out)
	}
}
