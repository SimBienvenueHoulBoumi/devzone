package manifest

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// writeFile creates path under root with content, creating its folders.
func writeFile(t *testing.T, root, rel, content string) {
	t.Helper()
	p := filepath.Join(root, filepath.FromSlash(rel))
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

// fakePackage builds the files a devzone copies from a package, plus one file
// that is not copied (bin/), and returns its root.
func fakePackage(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	writeFile(t, root, ".devcontainer/devzone", "a")
	writeFile(t, root, ".devcontainer/argocd/gitops.sh", "b")
	writeFile(t, root, "Makefile", "c")
	writeFile(t, root, "README.md", "d")
	writeFile(t, root, "LICENSE", "e")
	writeFile(t, root, ".gitattributes", "f")
	writeFile(t, root, "manage/scripts/devzone-create.sh", "g")
	writeFile(t, root, "bin/devzone-linux-amd64", "not copied")
	writeFile(t, root, "manage/test/update.bats", "not copied")
	return root
}

// TestChecksumIsSHA256 checks the digest of a known content: the manifest must
// stay compatible with the sums the shell version wrote.
func TestChecksumIsSHA256(t *testing.T) {
	p := filepath.Join(t.TempDir(), "f")
	if err := os.WriteFile(p, []byte("abc"), 0o644); err != nil {
		t.Fatal(err)
	}
	got, err := Checksum(p)
	if err != nil {
		t.Fatal(err)
	}
	want := "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
	if got != want {
		t.Fatalf("Checksum = %s, want %s", got, want)
	}
}

// TestPackageFilesListsOnlyCopiedFiles checks that the package list holds the
// copied items, sorted, and none of the files a devzone does not get.
func TestPackageFilesListsOnlyCopiedFiles(t *testing.T) {
	root := fakePackage(t)
	got, err := PackageFiles(root)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{
		".devcontainer/argocd/gitops.sh",
		".devcontainer/devzone",
		".gitattributes",
		"LICENSE",
		"Makefile",
		"README.md",
		"manage/scripts/devzone-create.sh",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("PackageFiles = %q, want %q", got, want)
	}
}

// TestWriteThenRead checks the round trip: the version and each checksum are read
// back, and a manifest without version reports UnknownVersion.
func TestWriteThenRead(t *testing.T) {
	folder := t.TempDir()
	writeFile(t, folder, "Makefile", "make")
	writeFile(t, folder, "manage/scripts/x.sh", "x")
	if err := Write(folder, "1.2.3", []string{"Makefile", "manage/scripts/x.sh"}); err != nil {
		t.Fatal(err)
	}
	if v := FolderVersion(folder); v != "1.2.3" {
		t.Fatalf("FolderVersion = %q", v)
	}
	sum, ok := ManifestChecksum(folder, "Makefile")
	want, _ := Checksum(filepath.Join(folder, "Makefile"))
	if !ok || sum != want {
		t.Fatalf("ManifestChecksum = %q, %v; want %q", sum, ok, want)
	}
	if _, ok := ManifestChecksum(folder, "LICENSE"); ok {
		t.Fatal("a file absent from the manifest was found")
	}
	if got := ManifestFiles(folder); !reflect.DeepEqual(got, []string{"Makefile", "manage/scripts/x.sh"}) {
		t.Fatalf("ManifestFiles = %q", got)
	}
	if v := FolderVersion(t.TempDir()); v != UnknownVersion {
		t.Fatalf("FolderVersion without manifest = %q", v)
	}
}

// TestManifestLineWithoutDoubleSpace checks that a line with no checksum is read
// as a path with no sum, as the shell did, and that the version line is skipped.
func TestManifestLineWithoutDoubleSpace(t *testing.T) {
	folder := t.TempDir()
	body := "version 1\n\nsingle-token\n"
	if err := os.WriteFile(filepath.Join(folder, FileName), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := ManifestFiles(folder); !reflect.DeepEqual(got, []string{"single-token"}) {
		t.Fatalf("ManifestFiles = %q", got)
	}
}

// TestFolderVersionOnlyFirstLine checks that a "version" text on another line is
// not taken for the version of the folder.
func TestFolderVersionOnlyFirstLine(t *testing.T) {
	folder := t.TempDir()
	body := "not-a-version\nversion 9.9.9\n"
	if err := os.WriteFile(filepath.Join(folder, FileName), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	if v := FolderVersion(folder); v != UnknownVersion {
		t.Fatalf("FolderVersion = %q, want %q", v, UnknownVersion)
	}
	if strings.Contains(FolderVersion(folder), "9.9.9") {
		t.Fatal("a later line was read as the version")
	}
}
