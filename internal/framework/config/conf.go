package config

import (
	"os"
	"strings"
)

// confSectionOf returns the trimmed name inside a "[...]" header.
func confSectionOf(line string) string {
	s := strings.TrimPrefix(line, "[")
	s = strings.TrimSuffix(s, "]")
	return strings.TrimSpace(s)
}

// GetKeyInSection returns the value of key in section from the config file
// at path. Returns empty string when the section or key is absent, the file
// is missing or unreadable, or the value contains spaces, newlines, or starts
// with '-' (invalid context name).
func GetKeyInSection(path, section, key string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	inSection := false
	for _, raw := range strings.Split(string(data), "\n") {
		line := strings.Trim(raw, " \t")
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") {
			if confSectionOf(line) == section {
				inSection = true
			} else {
				inSection = false
			}
			continue
		}
		if !inSection {
			continue
		}
		eq := strings.IndexByte(line, '=')
		if eq < 0 {
			continue
		}
		k := strings.TrimSpace(line[:eq])
		v := strings.TrimSpace(line[eq+1:])
		if k == key {
			if i := strings.IndexByte(v, '#'); i >= 0 {
				v = v[:i]
			}
			v = strings.TrimSpace(v)
			if hasInvalidContextValue(v) {
				return ""
			}
			return v
		}
	}
	return ""
}

func hasInvalidContextValue(v string) bool {
	if strings.Contains(v, " ") || strings.Contains(v, "\n") || strings.HasPrefix(v, "-") {
		return true
	}
	return false
}
