package createmode

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
)

// Write records workspace=<mode> in the module file of a folder. An earlier
// workspace line is replaced and the other lines are kept; a temporary file
// keeps a failed write from leaving a half-written module file.
func Write(folder, mode string) error {
	path := filepath.Join(folder, ".devzone.modules")
	var kept strings.Builder
	data, err := os.ReadFile(path)
	if err == nil {
		for _, line := range strings.Split(strings.TrimRight(string(data), "\n"), "\n") {
			if line == "" {
				continue
			}
			if strings.HasPrefix(line, "workspace=") {
				continue
			}
			kept.WriteString(line)
			kept.WriteByte('\n')
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	kept.WriteString("workspace=")
	kept.WriteString(mode)
	kept.WriteByte('\n')
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, []byte(kept.String()), 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}
