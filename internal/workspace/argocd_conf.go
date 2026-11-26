package workspace

import (
	"os"
	"strings"
)

// confValue returns the value of a key in a section of an Argo CD conf file,
// as conf_get in .devcontainer/argocd/conf.sh: sections are "[<name>]", keys
// are "key = value" and comments after # are ignored. It is the small part of
// the shared declaration format the workstation status needs; keeping it here
// avoids linking the whole pod Argo CD module into the workstation binary.
func confValue(path, section, key string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	current := ""
	for _, line := range strings.Split(string(data), "\n") {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "[") && strings.HasSuffix(trimmed, "]") {
			current = strings.TrimSpace(trimmed[1 : len(trimmed)-1])
			continue
		}
		if current != section || !strings.Contains(trimmed, "=") {
			continue
		}
		parts := strings.SplitN(trimmed, "=", 2)
		if strings.TrimSpace(parts[0]) != key {
			continue
		}
		value := strings.SplitN(parts[1], "#", 2)[0]
		return strings.TrimSpace(value)
	}
	return ""
}
