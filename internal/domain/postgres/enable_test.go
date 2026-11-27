package postgres

import (
	"io/fs"
	"os"
	osexec "os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// launcherCopy copies the .devcontainer folder of the repository to a temp
// folder, with a fake Go pod for both architectures: the launcher then runs
// without the program built by the image (bin/ is not copied). The fake pod
// accepts every command and prints nothing; the state file is the one the test
// writes, since the pod is what creates it in the image.
func launcherCopy(t *testing.T) string {
	t.Helper()
	src := repoDevcontainer(t)
	dst := t.TempDir()
	err := filepath.WalkDir(src, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(src, path)
		if err != nil {
			return err
		}
		if d.IsDir() {
			if rel == "bin" {
				return filepath.SkipDir
			}
			return os.MkdirAll(filepath.Join(dst, rel), 0o755)
		}
		info, err := d.Info()
		if err != nil {
			return err
		}
		body, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		return os.WriteFile(filepath.Join(dst, rel), body, info.Mode().Perm())
	})
	if err != nil {
		t.Fatal(err)
	}
	bin := filepath.Join(dst, "bin")
	if err := os.MkdirAll(bin, 0o755); err != nil {
		t.Fatal(err)
	}
	// The summary is now handled by the Go pod, like every other command.
	fakePod := "#!/usr/bin/env bash\n" +
		"case \"${1:-}\" in\n" +
		"    handles) exit 0 ;;\n" +
		"esac\n" +
		"exit 0\n"
	for _, arch := range []string{"amd64", "arm64"} {
		if err := os.WriteFile(filepath.Join(bin, "devzone-pod-linux-"+arch), []byte(fakePod), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	return dst
}

// runDevzone runs the launcher of a copy of the repository with the isolated environment of a test.
func runDevzone(t *testing.T, args ...string) (string, int) {
	t.Helper()
	command := osexec.Command("bash", append([]string{filepath.Join(launcherCopy(t), "devzone")}, args...)...)
	command.Stdin = strings.NewReader("")
	out, err := command.CombinedOutput()
	if err == nil {
		return string(out), 0
	}
	if exit, ok := err.(*osexec.ExitError); ok {
		return string(out), exit.ExitCode()
	}
	t.Fatalf("devzone: %v", err)
	return "", 1
}

// TestEnableContextMismatch checks that a --context different from the saved
// cluster is refused with the devzone cluster hint and disables the module.
func TestEnableContextMismatch(t *testing.T) {
	f := newFixture(t)
	writeState(t, "cluster=kind-devzone")
	writeDevzoneStub(t, `if [ "$1 $2" = "kube saved" ]; then printf 'kind-devzone'; exit 0; fi
exit 1
`)
	body := `
apply_postgres on --context host-cluster
`
	out, code := shellServices(t, body, "")
	if code != 2 || !strings.Contains(out, "devzone cluster host-cluster") {
		t.Fatalf("mismatch: code %d, output %q", code, out)
	}
	if data, err := os.ReadFile(f.statePath); err != nil || !strings.Contains(string(data), "postgres=off") {
		t.Fatalf("state = %q, err %v", data, err)
	}
}
