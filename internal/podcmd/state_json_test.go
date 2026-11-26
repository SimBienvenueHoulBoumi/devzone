package podcmd

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/cli"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec"
	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/state"
)

// stubRunner answers only the commands programmed by the tests, so no test
// reaches a real kubectl, gh, devzone or network service.
type stubRunner struct {
	t         *testing.T
	responses map[string]exec.Result
}

// Run implements exec.Runner with an exact name, argument and environment match.
func (r stubRunner) Run(_ context.Context, name string, args []string, opts exec.Opts) (exec.Result, error) {
	key := name + "\x00" + strings.Join(args, "\x00")
	if len(opts.Env) > 0 {
		key += "\x00" + strings.Join(opts.Env, "\x00")
	}
	res, ok := r.responses[key]
	if !ok {
		r.t.Fatalf("unexpected command: %s %v env=%v", name, args, opts.Env)
		return exec.Result{}, fmt.Errorf("unexpected command")
	}
	return res, nil
}

// program adds one answer to the stub runner.
func (r stubRunner) program(env []string, code int, stdout, name string, args ...string) {
	key := name + "\x00" + strings.Join(args, "\x00")
	if len(env) > 0 {
		key += "\x00" + strings.Join(env, "\x00")
	}
	r.responses[key] = exec.Result{Stdout: []byte(stdout), Code: code}
}

// jsonFixture creates a disposable root, code folder, state and cached version.
func jsonFixture(t *testing.T) (root, code, stateFile string) {
	t.Helper()
	root = t.TempDir()
	code = filepath.Join(root, ".devcontainer")
	stateFile = filepath.Join(root, ".devzone.modules")
	writeJSONFile(t, filepath.Join(code, "devzone"), "")
	writeJSONFile(t, filepath.Join(root, "manage", "scripts", "ci", "versions.sh"), "")
	writeJSONFile(t, filepath.Join(root, "workspace", "repo", ".git", "keep"), "")
	home := filepath.Join(root, "home")
	cache := filepath.Join(home, ".cache", "devzone", "version-publiee")
	writeJSONFile(t, cache, time.Now().Format("2006-01-02")+"\n3.2.2\n")
	t.Setenv("HOME", home)
	t.Setenv("DEVZONE_ROOT", root)
	t.Setenv("DEVZONE_STATE", stateFile)
	t.Setenv("DEVZONE_POD_SCRIPT", filepath.Join(code, "devzone"))
	t.Setenv("DEVZONE_KUBE_HOST", filepath.Join(root, "host.config"))
	t.Setenv("DEVZONE_PACKAGES_MARKER", filepath.Join(root, "packages.failed"))
	t.Setenv("DEVZONE_WORKSPACE", "")
	t.Setenv("DEVZONE_INSTANCE", "")
	return root, code, stateFile
}

// writeJSONFile writes a file in a disposable test tree.
func writeJSONFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

// renderJSON runs the Go JSON command with the stub runner.
func renderJSON(t *testing.T, runner stubRunner, stateFile string) (int, string) {
	t.Helper()
	var out, errOut strings.Builder
	ctx := &cli.Context{Out: &out, Err: &errOut, Runner: runner}
	code := runStateJSON(ctx, state.At(stateFile))
	if errOut.Len() > 0 {
		t.Fatalf("unexpected stderr: %s", errOut.String())
	}
	return code, out.String()
}

// checkJSON compares the output with a frozen expectation after replacing the
// disposable root by a stable marker.
func checkJSON(t *testing.T, root, got, want string) {
	t.Helper()
	normalized := strings.ReplaceAll(got, root, "<ROOT>")
	if normalized != want {
		t.Fatalf("frozen JSON differs:\nwant:\n%s\ngot:\n%s\n%s", want, normalized, firstJSONDiff(want, normalized))
	}
}

// firstJSONDiff reports the first differing line of two frozen outputs.
func firstJSONDiff(want, got string) string {
	a := strings.Split(want, "\n")
	b := strings.Split(got, "\n")
	for i := 0; i < len(a) || i < len(b); i++ {
		left, right := "", ""
		if i < len(a) {
			left = a[i]
		}
		if i < len(b) {
			right = b[i]
		}
		if left != right {
			return fmt.Sprintf("line %d: want %q, got %q", i+1, left, right)
		}
	}
	return ""
}
