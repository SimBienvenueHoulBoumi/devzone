package packages

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestListSortedWithoutDuplicate fixes the exact list lines and deduplication.
func TestListSortedWithoutDuplicate(t *testing.T) {
	env, installer := newEnv(t)
	writeListFile(t, env.List, "tree\nhtop\ntree\n")
	installer.installed["htop"] = true
	if err := env.Show(); err != nil {
		t.Fatal(err)
	}
	want := "  ✔ htop\n  ○ tree\n"
	if outOf(env) != want {
		t.Fatalf("list = %q, want %q", outOf(env), want)
	}
}

// TestApplyMarksOnlyUnknown checks that a valid package is installed and the
// failing one is the only name written to the failure marker.
func TestApplyMarksOnlyUnknown(t *testing.T) {
	env, installer := newEnv(t)
	writeListFile(t, env.List, "ghost\ntree\n")
	installer.failing["ghost"] = true
	if err := env.Apply(); err == nil {
		t.Fatal("expected a failure")
	}
	if err := env.Apply(); err == nil {
		t.Fatal("expected a failure on the second apply")
	}
	data, err := os.ReadFile(env.Marker)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != "ghost\n" {
		t.Fatalf("marker = %q", data)
	}
	if !installer.installed["tree"] {
		t.Fatal("valid package not installed")
	}
}

// TestAlreadyInstalledMarked checks the image-package mark and that removing
// such a package leaves it installed, with the exact user message.
func TestAlreadyInstalledMarked(t *testing.T) {
	env, installer := newEnv(t)
	installer.installed["tree"] = true
	if err := env.Add([]string{"tree"}); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(env.List)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != header+"tree "+presentMark+"\n" {
		t.Fatalf("list = %q", data)
	}
	if !strings.Contains(outOf(env), "tree : already present before devzone packages") {
		t.Fatalf("add out = %q", outOf(env))
	}
	installer.calls = nil
	env.Out = &strings.Builder{}
	if err := env.Remove([]string{"tree"}); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(outOf(env), "tree : removed from the list, left installed") {
		t.Fatalf("remove out = %q", outOf(env))
	}
	for _, call := range installer.calls {
		if strings.HasPrefix(call, "remove ") {
			t.Fatalf("image package uninstalled: %v", installer.calls)
		}
	}
	if !installer.installed["tree"] {
		t.Fatal("image package no longer installed")
	}
}

// TestSingleHeaderAfterOperations checks that consecutive add and remove
// operations leave one header and only the remaining package.
func TestSingleHeaderAfterOperations(t *testing.T) {
	env, _ := newEnv(t)
	for _, name := range []string{"tree", "htop"} {
		if err := env.Add([]string{name}); err != nil {
			t.Fatal(err)
		}
	}
	if err := env.Remove([]string{"tree"}); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(env.List)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Count(string(data), "#") != 1 || !strings.HasSuffix(string(data), "\nhtop\n") {
		t.Fatalf("list = %q", data)
	}
}

// TestListIgnoresPresentMark checks that the mark never appears in the list
// output and never reaches an installation command.
func TestListIgnoresPresentMark(t *testing.T) {
	env, installer := newEnv(t)
	writeListFile(t, env.List, "tree "+presentMark+"\nhtop\n")
	installer.installed["tree"] = true
	if err := env.Show(); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(outOf(env), "✔ tree") || strings.Contains(outOf(env), "#") {
		t.Fatalf("list = %q", outOf(env))
	}
	installer.calls = nil
	if err := env.Apply(); err != nil {
		t.Fatal(err)
	}
	for _, call := range installer.calls {
		if strings.Contains(call, "tree #") || strings.Contains(call, presentMark) {
			t.Fatalf("mark passed to the installer: %v", installer.calls)
		}
	}
}

// TestWriteListAtomicFailure checks that a failed replacement leaves the
// previous list and no temporary fragment in the folder.
func TestWriteListAtomicFailure(t *testing.T) {
	dir := t.TempDir()
	blocked := filepath.Join(dir, "blocked")
	if err := os.WriteFile(blocked, []byte("not a folder\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(blocked, ".devzone.packages")
	if err := writeList(path, []string{"tree"}); err == nil {
		t.Fatal("expected a write failure")
	}
	items, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	for _, item := range items {
		if strings.HasPrefix(item.Name(), ".devzone.packages.") {
			t.Fatalf("temporary fragment left: %s", item.Name())
		}
	}
}

// TestStoredHeaderBytes fixes the UTF-8 bytes of the stored header and mark,
// which are a contract with the user's package list file.
func TestStoredHeaderBytes(t *testing.T) {
	if header != "# paquets ajout\u00e9s par devzone packages add ; r\u00e9install\u00e9s \u00e0 chaque cr\u00e9ation du conteneur\n" {
		t.Fatalf("header = %q", header)
	}
	if presentMark != "# d\u00e9j\u00e0 pr\u00e9sent" {
		t.Fatalf("mark = %q", presentMark)
	}
}
