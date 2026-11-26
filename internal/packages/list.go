package packages

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// header is written byte for byte at the top of the user's package list.
const header = "# paquets ajoutés par devzone packages add ; réinstallés à chaque création du conteneur\n"

// presentMark tags a package that was already installed by the image.
const presentMark = "# déjà présent"

// PresentMark returns the exact mark written for an image package.
func PresentMark() string { return presentMark }

// readLines returns the meaningful lines of the list, trimmed and sorted by
// package name without duplicates, as list_lines of the shell did.
func readLines(path string) []string {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	seen := map[string]bool{}
	var lines []string
	for _, raw := range strings.Split(string(data), "\n") {
		line := strings.TrimSpace(raw)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		name := strings.Fields(line)[0]
		if seen[name] {
			continue
		}
		seen[name] = true
		lines = append(lines, line)
	}
	sort.SliceStable(lines, func(i, j int) bool { return nameOf(lines[i]) < nameOf(lines[j]) })
	return lines
}

// nameOf returns the package name at the start of a list line.
func nameOf(line string) string {
	fields := strings.Fields(line)
	if len(fields) == 0 {
		return ""
	}
	return fields[0]
}

// readNames returns the package names only, ignoring the end-of-line mark.
func readNames(path string) []string {
	seen := map[string]bool{}
	var names []string
	for _, line := range readLines(path) {
		name := nameOf(line)
		if !seen[name] {
			seen[name] = true
			names = append(names, name)
		}
	}
	return names
}

// containsName reports whether name is in the list of names.
func containsName(names []string, name string) bool {
	for _, candidate := range names {
		if candidate == name {
			return true
		}
	}
	return false
}

// isMarkedPresent reports whether the line of name carries the image mark.
func isMarkedPresent(lines []string, name string) bool {
	for _, line := range lines {
		if line == name+" "+presentMark {
			return true
		}
	}
	return false
}

// writeList replaces the user's list with a single header and the given
// lines. The temporary file is in the same folder, so the replacement is
// atomic, and its mode is 600.
func writeList(path string, lines []string) error {
	var data strings.Builder
	data.WriteString(header)
	seen := map[string]bool{}
	sorted := append([]string(nil), lines...)
	sort.SliceStable(sorted, func(i, j int) bool { return nameOf(sorted[i]) < nameOf(sorted[j]) })
	for _, line := range sorted {
		name := nameOf(line)
		if seen[name] {
			continue
		}
		seen[name] = true
		data.WriteString(line)
		data.WriteByte('\n')
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".devzone.packages.*")
	if err != nil {
		return err
	}
	name := tmp.Name()
	done := false
	defer func() {
		_ = tmp.Close()
		if !done {
			_ = os.Remove(name)
		}
	}()
	if err := tmp.Chmod(0o600); err != nil {
		return err
	}
	if _, err := tmp.WriteString(data.String()); err != nil {
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Rename(name, path); err != nil {
		return err
	}
	done = true
	return nil
}
