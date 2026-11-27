package workspace

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

// coreDumpSizeLimit is the size above which a core file is reported, in bytes.
const coreDumpSizeLimit = 100 << 20

// coreDumpSize returns the size of a regular file on disk.
func coreDumpSize(path string) int64 {
	info, err := os.Stat(path)
	if err != nil {
		return 0
	}
	return info.Size()
}

// isCoreDumpName reports whether a name is a core dump at a work folder root.
// Only numeric suffixes are accepted, so source files such as core.go are not
// mistaken for dumps.
func isCoreDumpName(name string) bool {
	if name == "core" {
		return true
	}
	suffix, ok := strings.CutPrefix(name, "core.")
	if !ok || suffix == "" {
		return false
	}
	for _, r := range suffix {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}

// largestCoreDump walks the pod work folders and returns the path of the
// biggest core dump over the limit. The size function is injected so tests can
// use a fake folder without creating a real large file.
func largestCoreDump(root string, size func(string) int64) string {
	if size == nil {
		size = coreDumpSize
	}
	biggest := ""
	var limit int64
	_ = filepath.WalkDir(root, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if entry.IsDir() {
			if entry.Name() == ".git" || entry.Name() == "node_modules" {
				return filepath.SkipDir
			}
			return nil
		}
		if !entry.Type().IsRegular() || !isCoreDumpName(entry.Name()) {
			return nil
		}
		if n := size(path); n > coreDumpSizeLimit && n > limit {
			biggest, limit = path, n
		}
		return nil
	})
	return biggest
}

// reportLargeCoreDumps writes one warning for a core dump left in a work
// folder, so it can be removed before git add picks it up.
func reportLargeCoreDumps(out io.Writer, root string, size func(string) int64) {
	path := largestCoreDump(root, size)
	if path == "" {
		return
	}
	fmt.Fprintf(out, "⚠ large core dump in the pod: %s (>100 MiB); remove it before committing\n", path)
}
