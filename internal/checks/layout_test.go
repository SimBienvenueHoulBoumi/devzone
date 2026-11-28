//go:build !windows

package checks

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/SimBienvenueHoulBoumi/devzone/internal/framework/testkit"
)

// newLayoutRepo creates a local repository in a disposable folder.
func newLayoutRepo(t *testing.T) string {
	t.Helper()
	testkit.RequireGit(t)
	root := t.TempDir()
	testkit.Git(t, root, "init", "-q")
	return root
}

// writeGoFile writes a Go file of n comment lines in the repository.
func writeGoFile(t *testing.T, root, path string, n int) {
	t.Helper()
	full := filepath.Join(root, filepath.FromSlash(path))
	if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
		t.Fatal(err)
	}
	var text strings.Builder
	for i := 0; i < n; i++ {
		text.WriteString("// line\n")
	}
	if err := os.WriteFile(full, []byte(text.String()), 0o644); err != nil {
		t.Fatal(err)
	}
}

// runLayoutCheck runs the line count check and returns its output and code.
func runLayoutCheck(t *testing.T, root string) (string, int) {
	t.Helper()
	var out, errOut bytes.Buffer
	code := RunLayout(root, &out, &errOut)
	if errOut.Len() > 0 {
		t.Fatalf("unexpected stderr: %s", errOut.String())
	}
	return out.String(), code
}

// TestLayoutRejects251Lines checks the failing side of the ceiling.
func TestLayoutRejects251Lines(t *testing.T) {
	root := newLayoutRepo(t)
	writeGoFile(t, root, "internal/big.go", 251)
	output, code := runLayoutCheck(t, root)
	if code != 1 {
		t.Fatalf("exit code = %d, want 1; output %q", code, output)
	}
	if !strings.Contains(output, "internal/big.go: 251 lines (max 250)") {
		t.Errorf("output = %q, want the path and the count", output)
	}
}

// TestLayoutAccepts250Lines checks the ceiling, with and without a final newline.
func TestLayoutAccepts250Lines(t *testing.T) {
	root := newLayoutRepo(t)
	writeGoFile(t, root, "internal/limit_test.go", 250)
	output, code := runLayoutCheck(t, root)
	if code != 0 || output != "go layout: 1 files ok\n" {
		t.Fatalf("got %d and %q, want 0 and the ok line", code, output)
	}
	full := filepath.Join(root, "internal", "limit_test.go")
	data, err := os.ReadFile(full)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(full, data[:len(data)-1], 0o644); err != nil {
		t.Fatal(err)
	}
	output, code = runLayoutCheck(t, root)
	if code != 0 || output != "go layout: 1 files ok\n" {
		t.Fatalf("without final newline: got %d and %q", code, output)
	}
}

// TestLayoutWithoutGoFile checks an empty run.
func TestLayoutWithoutGoFile(t *testing.T) {
	root := newLayoutRepo(t)
	if err := os.WriteFile(filepath.Join(root, "notes.txt"), []byte("text only\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	output, code := runLayoutCheck(t, root)
	if code != 0 || output != "go layout: 0 files ok\n" {
		t.Fatalf("got %d and %q, want 0 and the empty ok line", code, output)
	}
}

// TestLayoutIgnoresIgnoredFile excludes an ignored Go file from the count.
func TestLayoutIgnoresIgnoredFile(t *testing.T) {
	root := newLayoutRepo(t)
	if err := os.WriteFile(filepath.Join(root, ".gitignore"), []byte("vendor/\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	writeGoFile(t, root, "vendor/long.go", 300)
	output, code := runLayoutCheck(t, root)
	if code != 0 || output != "go layout: 0 files ok\n" {
		t.Fatalf("got %d and %q, want 0 and the empty ok line", code, output)
	}
}
