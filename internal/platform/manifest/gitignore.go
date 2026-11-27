package manifest

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

// GitignoreLines are the lines always present in the .gitignore of a devzone.
var GitignoreLines = []string{
	"# Each workspace project has its own git repository",
	"workspace/*",
	"!workspace/.gitkeep",
	".DS_Store",
	".devzone.log",
	".devzone.state",
	".password",
	".devzone.backup/",
}

// CompleteGitignore appends to the .gitignore of folder each line of
// GitignoreLines that it does not hold yet, and creates the file when it is
// missing. Why: the lines are added, never overwritten, so the lines the user
// wrote stay as they are. A last line without a newline is closed first, so the
// appended line is never glued to it.
func CompleteGitignore(folder string) error {
	path := filepath.Join(folder, ".gitignore")
	data, err := os.ReadFile(path)
	if err != nil && !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	have := map[string]bool{}
	for _, line := range strings.Split(string(data), "\n") {
		have[line] = true
	}
	var add strings.Builder
	if len(data) > 0 && !strings.HasSuffix(string(data), "\n") {
		add.WriteString("\n")
	}
	for _, line := range GitignoreLines {
		if !have[line] {
			add.WriteString(line + "\n")
		}
	}
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	if _, err := f.WriteString(add.String()); err != nil {
		_ = f.Close()
		return err
	}
	return f.Close()
}
