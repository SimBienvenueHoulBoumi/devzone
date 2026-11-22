package workspace

import (
	"os"
	"strconv"
	"strings"
)

// readModulesKey returns the value of the last line of the modules file that
// starts with key=, like state_read in argocd-workspace.sh. It is a common
// building block for argocd, services, egress, start and update: all of them
// need the same state written by the shell. A missing file or an absent key
// gives an empty value. The shell reads the key as a regular expression, while
// Go compares it as plain text; this difference is accepted.
func readModulesKey(path, key string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	prefix := key + "="
	value := ""
	for _, line := range strings.Split(string(data), "\n") {
		if !strings.HasPrefix(line, prefix) {
			continue
		}
		equal := strings.IndexByte(line, '=')
		value = line[equal+1:]
	}
	return value
}

// noteModulesKey writes key=value at the end of the modules file, after
// removing every line that starts with key=, like state_note in
// argocd-workspace.sh. Other lines are kept in order, blank lines included.
// It is a common building block for argocd, services, egress, start and update,
// which share this state. The write goes through a neighbor temporary file and
// a rename, with mode 0644. The shell reads the key as a regular expression,
// while Go compares it as plain text; this difference is accepted.
func noteModulesKey(path, key, value string) error {
	prefix := key + "="
	var lines []string
	if data, err := os.ReadFile(path); err == nil {
		text := strings.TrimSuffix(string(data), "\n")
		if len(text) > 0 || len(data) > 0 {
			lines = strings.Split(text, "\n")
		}
	} else if !os.IsNotExist(err) {
		return err
	}
	var out strings.Builder
	for _, line := range lines {
		if strings.HasPrefix(line, prefix) {
			continue
		}
		out.WriteString(line)
		out.WriteByte('\n')
	}
	out.WriteString(key)
	out.WriteByte('=')
	out.WriteString(value)
	out.WriteByte('\n')
	tmp := path + ".tmp." + strconv.Itoa(os.Getpid())
	if err := os.WriteFile(tmp, []byte(out.String()), 0o644); err != nil {
		return err
	}
	if err := os.Chmod(tmp, 0o644); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return nil
}
