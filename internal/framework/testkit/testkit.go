// Package testkit provides small helpers for Go tests.
package testkit

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/exec/fake"
)

var updateGolden = flag.Bool("update", false, "update golden files")

// TempHome creates a temporary HOME and points HOME at it for the duration of
// the test. It returns the directory.
func TempHome(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("HOME", dir)
	return dir
}

// FakeRunner returns a programmable fake runner.
func FakeRunner(t *testing.T) *fake.Runner {
	t.Helper()
	return fake.New()
}

// Golden compares got to the contents of testdata/<name>, updating it when
// -update is passed.
func Golden(t *testing.T, name string, got any) {
	t.Helper()
	path := filepath.Join("testdata", name)
	text := fmt.Sprint(got)
	// convert []byte to string when needed
	if b, ok := got.([]byte); ok {
		text = string(b)
	}
	if *updateGolden {
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(text), 0o644); err != nil {
			t.Fatal(err)
		}
		return
	}
	want, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("golden file %s: %v", path, err)
	}
	if string(want) != text {
		t.Fatalf("golden mismatch for %s:\n--- want ---\n%s\n--- got ---\n%s", path, string(want), text)
	}
}

// podWorkspaceVars lists the variables that make the host program refuse to run
// in the pod; subprocess tests must remove them to stay hermetic in that context.
var podWorkspaceVars = []string{"DEVZONE_WORKSPACE", "DEVZONE_ROOT"}

// CommandEnv returns the process environment without the pod workspace
// variables, so subprocesses that launch the host program are not refused in
// the pod (#980).
func CommandEnv() []string {
	return FilterEnv(os.Environ(), podWorkspaceVars...)
}

// FilterEnv returns env without the named variables, preserving every other
// entry as-is.
func FilterEnv(env []string, names ...string) []string {
	drop := make(map[string]struct{}, len(names))
	for _, name := range names {
		drop[name] = struct{}{}
	}
	out := make([]string, 0, len(env))
	for _, entry := range env {
		key, _, ok := strings.Cut(entry, "=")
		if !ok {
			out = append(out, entry)
			continue
		}
		if _, found := drop[key]; found {
			continue
		}
		out = append(out, entry)
	}
	return out
}
