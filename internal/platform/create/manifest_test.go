package create

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestWriteManifest checks .devzone.version: `version`, then `<sha256>  <rel>`
// per package file, sorted, checksums of the copied files in the folder.
func TestWriteManifest(t *testing.T) {
	pkg := fakePackage(t)
	folder := t.TempDir()
	// copy first so checksums are of the copied files
	if err := copyPackage(pkg, folder); err != nil {
		t.Fatal(err)
	}
	if err := writeManifest(pkg, folder, "9.9.9"); err != nil {
		t.Fatal(err)
	}
	data, _ := os.ReadFile(filepath.Join(folder, ".devzone.version"))
	lines := strings.Split(strings.TrimSpace(string(data)), "\n")
	if lines[0] != "version 9.9.9" {
		t.Fatalf("first line %q", lines[0])
	}
	var rels []string
	for _, line := range lines[1:] {
		parts := strings.SplitN(line, "  ", 2)
		if len(parts) != 2 {
			t.Fatalf("line %q", line)
		}
		body, err := os.ReadFile(filepath.Join(folder, filepath.FromSlash(parts[1])))
		if err != nil {
			t.Fatal(err)
		}
		sum := sha256.Sum256(body)
		if hex.EncodeToString(sum[:]) != parts[0] {
			t.Fatalf("checksum mismatch on %s", parts[1])
		}
		rels = append(rels, parts[1])
	}
	if !sortedCopy(rels) {
		t.Fatalf("not sorted: %v", rels)
	}
	for _, want := range []string{"Makefile", "README.md", "LICENSE", ".gitattributes",
		".devcontainer/devzone", "manage/scripts/uninstall.sh"} {
		if !strings.Contains(string(data), "  "+want+"\n") {
			t.Fatalf("%s not listed:\n%s", want, data)
		}
	}
}

// sortedCopy tells whether s is sorted in C order.
func sortedCopy(s []string) bool {
	for i := 1; i < len(s); i++ {
		if s[i-1] > s[i] {
			return false
		}
	}
	return true
}

// TestCopyPackage checks a recursive copy of the package items, permissions
// kept, into target.
func TestCopyPackage(t *testing.T) {
	pkg := fakePackage(t)
	if err := os.WriteFile(filepath.Join(pkg, ".devcontainer", "bin", "x"), []byte("x"), 0o755); err != nil {
		_ = os.MkdirAll(filepath.Join(pkg, ".devcontainer", "bin"), 0o755)
		if err := os.WriteFile(filepath.Join(pkg, ".devcontainer", "bin", "x"), []byte("x"), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	target := t.TempDir()
	if err := copyPackage(pkg, target); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(filepath.Join(target, "manage", "scripts", "uninstall.sh"))
	if err != nil || string(data) != "#!/usr/bin/env bash\n" {
		t.Fatalf("uninstall.sh %q %v", data, err)
	}
	if _, err := os.Stat(filepath.Join(target, "package.json")); err == nil {
		t.Fatal("package.json copied; it is not a package item")
	}
	info, err := os.Stat(filepath.Join(target, ".devcontainer", "bin", "x"))
	if err != nil || info.Mode().Perm()&0o100 == 0 {
		t.Fatalf("executable bit lost: %v %v", info, err)
	}
}
