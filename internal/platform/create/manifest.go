package create

import (
	"crypto/sha256"
	"encoding/hex"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// writeManifest writes .devzone.version in folder: `version <version>`, then
// one `<sha256>  <relative path>` per package file, sorted, as write_manifest
// the former devzone-manifest.sh did; the checksums are of the copied files in folder.
func writeManifest(pkg, folder, version string) error {
	var b strings.Builder
	b.WriteString("version ")
	b.WriteString(version)
	b.WriteByte('\n')
	for _, rel := range relativePackageFiles(pkg) {
		sum, err := checksum(filepath.Join(folder, filepath.FromSlash(rel)))
		if err != nil {
			return err
		}
		b.WriteString(sum)
		b.WriteString("  ")
		b.WriteString(rel)
		b.WriteByte('\n')
	}
	return os.WriteFile(filepath.Join(folder, ".devzone.version"), []byte(b.String()), 0o644)
}

// relativePackageFiles lists the package files relative to pkg, sorted in C
// order, as relative_package_files does.
func relativePackageFiles(pkg string) []string {
	var rels []string
	for _, abs := range packageFiles(pkg) {
		rel, err := filepath.Rel(pkg, abs)
		if err != nil {
			continue
		}
		rels = append(rels, filepath.ToSlash(rel))
	}
	sort.Strings(rels)
	return rels
}

// packageFiles lists the absolute paths of the package files copied into a
// devzone: every file under PackageItems plus manage/scripts.
func packageFiles(pkg string) []string {
	var files []string
	for _, base := range PackageItems {
		files = append(files, filesUnder(filepath.Join(pkg, base))...)
	}
	files = append(files, filesUnder(filepath.Join(pkg, "manage", "scripts"))...)
	return files
}

// filesUnder lists every regular file at or under root; a plain file counts
// itself, a missing path lists nothing.
func filesUnder(root string) []string {
	var files []string
	info, err := os.Stat(root)
	if err != nil {
		return nil
	}
	if !info.IsDir() {
		return []string{root}
	}
	_ = filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if !d.IsDir() && d.Type().IsRegular() {
			files = append(files, path)
		}
		return nil
	})
	return files
}

// checksum returns the SHA-256 hex digest of a file, as the node checksum in
// the former devzone-manifest.sh did.
func checksum(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer func() { _ = f.Close() }()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// completeGitignore adds the missing GitignoreLines to the .gitignore of
// folder, never removing anything.
func completeGitignore(folder string) error {
	path := filepath.Join(folder, ".gitignore")
	data, _ := os.ReadFile(path)
	present := map[string]bool{}
	for _, line := range strings.Split(strings.TrimSuffix(string(data), "\n"), "\n") {
		present[line] = true
	}
	var add strings.Builder
	for _, line := range GitignoreLines {
		if !present[line] {
			add.WriteString(line)
			add.WriteByte('\n')
		}
	}
	if add.Len() == 0 {
		return nil
	}
	f, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY|os.O_CREATE, 0o644)
	if err != nil {
		return err
	}
	defer func() { _ = f.Close() }()
	_, err = f.WriteString(add.String())
	return err
}
