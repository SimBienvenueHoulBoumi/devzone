package catalog

import (
	"os"
	osexec "os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// shellApp copies the devzone entry point and its libraries into a temporary
// folder with fake tools, as the setup of the removed application.bats did.
func shellApp(t *testing.T) (appDir, actions, state string) {
	t.Helper()
	tmp := t.TempDir()
	app := filepath.Join(tmp, "app")
	bin := filepath.Join(tmp, "bin")
	root := filepath.Join(tmp, "racine")
	state = filepath.Join(tmp, "modules")
	for _, dir := range []string{app, bin, root, filepath.Join(app, "bin"), filepath.Join(app, "catalog"), filepath.Join(app, "ai"), filepath.Join(root, "workspace")} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	repo := repoPath(".devcontainer")
	copyFile(t, filepath.Join(repo, "devzone"), filepath.Join(app, "devzone"), 0o755)
	for _, name := range []string{"help.sh", "cluster.sh", "kube-account.sh", "host-models.sh", "host-check.sh", "host-check.message"} {
		src := filepath.Join(repo, name)
		if strings.HasPrefix(name, "host-") {
			src = filepath.Join(repo, "ai", name)
			copyFile(t, src, filepath.Join(app, "ai", name), 0o644)
			continue
		}
		copyFile(t, src, filepath.Join(app, name), 0o644)
	}
	entries, err := os.ReadDir(repo)
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		name := entry.Name()
		if !strings.HasPrefix(name, "devzone-") || !strings.HasSuffix(name, ".sh") {
			continue
		}
		copyFile(t, filepath.Join(repo, name), filepath.Join(app, name), 0o644)
	}
	writeTestFile(t, filepath.Join(app, "ports.sh"), "#!/usr/bin/env bash\nprintf 'ports %s\\n' \"$*\" >>\"$BATS_TEST_TMPDIR_ACTIONS\"\n")
	writeTestFile(t, filepath.Join(app, "password.sh"), "#!/usr/bin/env bash\nprintf 'password %s\\n' \"$*\" >>\"$BATS_TEST_TMPDIR_ACTIONS\"\n[ ! -f \"$TEST_FAILED_PASSWORD\" ] || { echo \"credentials unavailable\"; exit 1; }\n")
	writeTestFile(t, filepath.Join(app, "metrics-server.sh"), "#!/usr/bin/env bash\nprintf 'metrics %s\\n' \"$*\" >>\"$BATS_TEST_TMPDIR_ACTIONS\"\n")
	actions = filepath.Join(tmp, "actions.log")
	writeTestFile(t, actions, "")
	writeTestFile(t, filepath.Join(bin, "devzone"), "#!/usr/bin/env bash\nprintf 'devzone %s\\n' \"$*\" >>\"$BATS_TEST_TMPDIR_ACTIONS\"\ncase \"$*\" in\n    \"passwords regenerate\") [ ! -f \"$TEST_FAILED_PASSWORD\" ] || { echo \"credentials unavailable\" >&2; exit 1; } ;;\nesac\nexit 0\n")
	fakePod := "#!/usr/bin/env bash\n[ \"${1:-}\" = handles ] && exit 1\nexit 0\n"
	for _, arch := range []string{"amd64", "arm64"} {
		writeTestFile(t, filepath.Join(app, "bin", "devzone-pod-linux-"+arch), fakePod)
	}
	writeTestFile(t, filepath.Join(bin, "kubectl"), kubectlFake)
	writeTestFile(t, filepath.Join(bin, "kind"), "#!/usr/bin/env bash\nexit 0\n")
	makeExecutable(t, app, bin)
	writeTestFile(t, state, "")
	t.Setenv("HOME", filepath.Join(tmp, "home"))
	t.Setenv("DEVZONE_ROOT", root)
	t.Setenv("DEVZONE_STATE", state)
	t.Setenv("DEVZONE_NO_GO", "1")
	t.Setenv("BATS_TEST_TMPDIR", "")
	t.Setenv("BATS_TEST_TMPDIR_ACTIONS", actions)
	t.Setenv("TEST_FAILED_PASSWORD", filepath.Join(tmp, "failed-password"))
	for _, key := range []string{"GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM"} {
		t.Setenv(key, "")
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	return app, actions, state
}

// kubectlFake answers every config query of "devzone use" with data defined
// here: the local context is known only by this fake, so no test can lean on a
// real context of the machine. Its expectations are fixed, never read from the
// removed bats.
const kubectlFake = `#!/usr/bin/env bash
T="${BATS_TEST_TMPDIR_ACTIONS}"
printf 'kubectl %s\n' "$*" >>"${T}.kubectl"
case "$*" in
    "config get-contexts -o name") printf '%s\n' fake-local prod ;;
    *'config view'*'"fake-local"'*) printf '%s\n' cluster-fake ;;
    *'config view'*'"cluster-fake"'*) printf '%s\n' https://127.0.0.1:6443 ;;
esac
exit 0
`

// copyFile copies one fixture file with the requested mode.
func copyFile(t *testing.T, src, dst string, mode os.FileMode) {
	t.Helper()
	data, err := os.ReadFile(src)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(dst, data, mode); err != nil {
		t.Fatal(err)
	}
}

// makeExecutable gives the fake scripts and the entry point their exec bit.
func makeExecutable(t *testing.T, app, bin string) {
	t.Helper()
	entries, err := os.ReadDir(app)
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if strings.HasSuffix(entry.Name(), ".sh") || entry.Name() == "devzone" {
			_ = os.Chmod(filepath.Join(app, entry.Name()), 0o755)
		}
	}
	for _, dir := range []string{bin, filepath.Join(app, "bin")} {
		entries, err = os.ReadDir(dir)
		if err != nil {
			t.Fatal(err)
		}
		for _, entry := range entries {
			_ = os.Chmod(filepath.Join(dir, entry.Name()), 0o755)
		}
	}
}

// runShellApp runs the copied entry point with the given arguments.
func runShellApp(t *testing.T, app string, args ...string) (string, int) {
	t.Helper()
	cmd := osexec.Command(filepath.Join(app, "devzone"), args...)
	out, err := cmd.CombinedOutput()
	if err == nil {
		return string(out), 0
	}
	exitErr, ok := err.(*osexec.ExitError)
	if !ok {
		t.Fatalf("devzone: %v", err)
	}
	return string(out), exitErr.ExitCode()
}

// shellLog returns one line of the actions log, or an empty string.
func shellLog(t *testing.T, path, want string) string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	for _, line := range strings.Split(string(data), "\n") {
		if strings.Contains(line, want) {
			return line
		}
	}
	return ""
}

// TestShellHelpAndDocs checks that the entry point is the documented command
// and that the contributor docs no longer expose direct scripts or variables.
func TestShellHelpAndDocs(t *testing.T) {
	app, _, _ := shellApp(t)
	out, code := runShellApp(t, app, "--help")
	if code != 0 {
		t.Fatalf("help: code %d", code)
	}
	for _, cmd := range []string{"devzone repair", "devzone metrics", "devzone use", "devzone catalog"} {
		if !strings.Contains(out, cmd) {
			t.Fatalf("help misses %s", cmd)
		}
	}
	for _, name := range []string{"README.md", "manage/docs/reference.md"} {
		data, err := os.ReadFile(repoPath(name))
		if err != nil {
			t.Fatal(err)
		}
		content := string(data)
		if i := strings.Index(content, "## For contributors"); i >= 0 {
			content = content[:i]
		}
		for _, forbidden := range []string{"bash .devcontainer/", "kubectl config use-context"} {
			if strings.Contains(content, forbidden) {
				t.Fatalf("%s still exposes %s", name, forbidden)
			}
		}
	}
}

// TestShellRepair checks the watcher and credentials repair items.
func TestShellRepair(t *testing.T) {
	app, actions, _ := shellApp(t)
	out, code := runShellApp(t, app, "repair")
	if code != 0 {
		t.Fatalf("repair: code %d, output %q", code, out)
	}
	if !strings.Contains(out, "✔ catalog watcher") || !strings.Contains(out, "✔ credentials") {
		t.Fatalf("repair output = %q", out)
	}
	if shellLog(t, actions, "catalog-watcher start") == "" {
		t.Fatalf("actions = %q, want the watcher start", readLog(t, actions))
	}
	if shellLog(t, actions, "devzone passwords regenerate") == "" {
		t.Fatalf("actions = %q, want the credentials regeneration", readLog(t, actions))
	}
}

// TestShellRepairActiveServices checks that active modules are repaired too.
func TestShellRepairActiveServices(t *testing.T) {
	app, actions, state := shellApp(t)
	writeTestFile(t, state, "gitlab=on\npostgres=on\n")
	if _, code := runShellApp(t, app, "repair"); code != 0 {
		t.Fatalf("repair: code %d", code)
	}
	for _, want := range []string{"gitlab host-set", "gitlab relay-start", "postgres relay-start"} {
		if shellLog(t, actions, want) == "" {
			t.Fatalf("actions = %q, want %s", readLog(t, actions), want)
		}
	}
}

// TestShellRepairFailedCredentials checks the reason and status of a failure.
func TestShellRepairFailedCredentials(t *testing.T) {
	app, actions, _ := shellApp(t)
	failed := os.Getenv("TEST_FAILED_PASSWORD")
	writeTestFile(t, failed, "")
	out, code := runShellApp(t, app, "repair")
	if code != 1 {
		t.Fatalf("repair: code %d, want 1", code)
	}
	if !strings.Contains(out, "✖ credentials : credentials unavailable") {
		t.Fatalf("repair output = %q", out)
	}
	if shellLog(t, actions, "devzone passwords regenerate") == "" {
		t.Fatalf("actions = %q", readLog(t, actions))
	}
}
