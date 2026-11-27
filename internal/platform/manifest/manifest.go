// Package manifest reads and writes the .devzone.version manifest of a devzone
// folder: the version of the package the folder was made from, then the SHA-256
// of each file copied from the package. It is the Go port of
// manage/scripts/devzone-manifest.sh (#884, script removed). The update compares the files of a
// folder with this manifest before it replaces any of them, so the list of
// package files lives here once for both.
package manifest

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// FileName is the manifest written at the root of a devzone folder.
const FileName = ".devzone.version"

// UnknownVersion is reported for a folder or a package with no readable version.
// The value is the one the shell scripts printed, so the output does not change.
const UnknownVersion = "inconnue"

// packageItems are the entries of the package copied into a devzone, relative to
// the package root. A folder is copied with all its files; manage/scripts is
// always added on top (see PackageFiles).
var packageItems = []string{".devcontainer", "Makefile", ".gitattributes", "README.md", "LICENSE"}

// Checksum returns the SHA-256 of the file at path, in lowercase hexadecimal.
// The content is read through a symbolic link: the manifest records what the
// file contains, not where it points.
func Checksum(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:]), nil
}

// PackageFiles lists the files that a devzone copies from the package at root,
// relative to root with slashes, sorted bytewise. The manifest and the update both
// use this one list, so they can never disagree about which files belong to a
// devzone.
func PackageFiles(root string) ([]string, error) {
	items := append(append([]string{}, packageItems...), "manage/scripts")
	var out []string
	for _, item := range items {
		files, err := regularFiles(root, item)
		if err != nil {
			return nil, err
		}
		out = append(out, files...)
	}
	sort.Strings(out)
	return out, nil
}

// regularFiles lists the regular files under root/item. A folder is walked
// without following its links (find -type f did the same); a file is listed as
// itself, and a missing item gives nothing: a partial package is checked by the
// update, not refused here.
func regularFiles(root, item string) ([]string, error) {
	base := filepath.Join(root, filepath.FromSlash(item))
	info, err := os.Stat(base)
	if err != nil {
		return nil, nil
	}
	if !info.IsDir() {
		if info.Mode().IsRegular() {
			return []string{item}, nil
		}
		return nil, nil
	}
	var out []string
	err = filepath.WalkDir(base, func(path string, d fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if d.Type().IsRegular() {
			rel, relErr := filepath.Rel(root, path)
			if relErr != nil {
				return relErr
			}
			out = append(out, filepath.ToSlash(rel))
		}
		return nil
	})
	return out, err
}

// Write writes the manifest of folder: the version line, then one "checksum  path"
// line per file, in the order given. The file is written in one piece, after all
// the checksums are read, so a failure leaves the previous manifest in place.
func Write(folder, version string, files []string) error {
	var b strings.Builder
	fmt.Fprintf(&b, "version %s\n", version)
	for _, rel := range files {
		sum, err := Checksum(filepath.Join(folder, filepath.FromSlash(rel)))
		if err != nil {
			return err
		}
		fmt.Fprintf(&b, "%s  %s\n", sum, rel)
	}
	return os.WriteFile(filepath.Join(folder, FileName), []byte(b.String()), 0o644)
}

// FolderVersion returns the version written on the first line of the manifest of
// folder, or UnknownVersion when there is no manifest or no version. The update
// compares it with the package version to know whether anything has to change.
func FolderVersion(folder string) string {
	data, err := os.ReadFile(filepath.Join(folder, FileName))
	if err != nil {
		return UnknownVersion
	}
	first := strings.SplitN(string(data), "\n", 2)[0]
	if v, ok := strings.CutPrefix(first, "version "); ok && v != "" {
		return v
	}
	return UnknownVersion
}

// entry is one "checksum  path" line of a manifest.
type entry struct {
	sum  string
	path string
}

// entries reads the lines of the manifest of folder that describe a file. The
// version line and empty lines are skipped. A line without a double space has no
// checksum: its whole text is the path, as the shell parsing read it.
func entries(folder string) []entry {
	data, err := os.ReadFile(filepath.Join(folder, FileName))
	if err != nil {
		return nil
	}
	var out []entry
	for _, line := range strings.Split(string(data), "\n") {
		if line == "" || strings.HasPrefix(line, "version ") {
			continue
		}
		e := entry{sum: line, path: line}
		if i := strings.Index(line, "  "); i >= 0 {
			e = entry{sum: line[:i], path: line[i+2:]}
		}
		out = append(out, e)
	}
	return out
}

// ManifestChecksum returns the checksum recorded in the manifest of folder for
// the path rel, and false when the manifest does not list it. The update uses it
// to tell a file the user changed from one the package delivered.
func ManifestChecksum(folder, rel string) (string, bool) {
	for _, e := range entries(folder) {
		if e.path == rel {
			return e.sum, true
		}
	}
	return "", false
}

// ManifestFiles returns the paths listed in the manifest of folder, in the order
// of the manifest. The update reads them to find the files of an older package,
// which it may remove.
func ManifestFiles(folder string) []string {
	var out []string
	for _, e := range entries(folder) {
		out = append(out, e.path)
	}
	return out
}
