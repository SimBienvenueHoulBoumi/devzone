package create

import (
	"errors"
	"os"
	"strings"
)

// confHeader introduces a freshly created .argocd.conf, as conf.sh does.
const confHeader = `# Argo CD of devzone (#516): what devzone declares in its GitOps repository.
# Written by devzone (argocd init, app add, app remove), applied by
# devzone workspace argocd apply and by workspace start. Tokens never go
# here, only paths to them (token-file).
`

// confSet replaces section in the conf file at path with one key = value line,
// added at the end when absent; a missing file starts with confHeader, blank
// lines are squeezed, as conf_set in .devcontainer/argocd/conf.sh does.
func confSet(path, section, key, value string) error {
	var kept []string
	if data, err := os.ReadFile(path); err == nil {
		kept = confWithout(string(data), section)
	} else if errors.Is(err, os.ErrNotExist) {
		kept = strings.Split(strings.TrimSuffix(confHeader, "\n"), "\n")
	} else {
		return err
	}
	kept = append(kept, "", "["+section+"]", "    "+key+" = "+value)
	return os.WriteFile(path, []byte(joinSqueezed(kept)), 0o644)
}

// confWithout returns the lines of a conf file without section (its header and
// its keys); comments and blank lines are kept, as conf_without does.
func confWithout(content, section string) []string {
	var out []string
	skip := false
	for _, line := range splitLines(content) {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "[") && strings.HasSuffix(trimmed, "]") {
			name := strings.TrimSpace(strings.TrimSuffix(strings.TrimPrefix(trimmed, "["), "]"))
			if name == section {
				skip = true
				continue
			}
			skip = false
		}
		if skip {
			continue
		}
		out = append(out, line)
	}
	return out
}

// splitLines splits content on newlines; a final empty line after a trailing
// newline is dropped and a missing trailing newline does not add an empty line.
func splitLines(content string) []string {
	if content == "" {
		return nil
	}
	content = strings.TrimSuffix(content, "\n")
	return strings.Split(content, "\n")
}

// joinSqueezed joins lines with newlines, collapsing runs of empty lines into
// one, and ends with a single trailing newline, as `cat -s` does.
func joinSqueezed(lines []string) string {
	var out []string
	for _, line := range lines {
		if line == "" && len(out) > 0 && out[len(out)-1] == "" {
			continue
		}
		out = append(out, line)
	}
	return strings.Join(out, "\n") + "\n"
}
