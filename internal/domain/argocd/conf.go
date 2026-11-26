package argocd

import (
	"os"
	"path/filepath"
	"strings"
)

// ConfEntry is one key=value line of a section in .argocd.conf.
type ConfEntry struct {
	Section string
	Key     string
	Value   string
}

// Conf reads and writes the .argocd.conf file: the declaration of the Argo CD
// of devzone, versioned with the devzone folder. Tokens never go in it, only
// paths to them.
type Conf struct {
	Path string
}

// confHeader is the comment written at the top of a file created by confSet.
const confHeader = `# Argo CD of devzone (#516): what devzone declares in its GitOps repository.
# Written by devzone (argocd init, app add, app remove), applied by
# devzone workspace argocd apply and by workspace start. Tokens never go
# here, only paths to them (token-file).
`

// confTrim removes the leading and trailing spaces and tabs of s.
func confTrim(s string) string {
	return strings.Trim(s, " \t")
}

// confSectionOf returns the trimmed name inside a "[...]" header.
func confSectionOf(line string) string {
	s := strings.TrimPrefix(line, "[")
	s = strings.TrimSuffix(s, "]")
	return confTrim(s)
}

// Entries returns the key=value lines of the file as entries; comments, blank
// lines and lines without "=" are dropped.
func (c Conf) Entries() []ConfEntry {
	data, err := os.ReadFile(c.Path)
	if err != nil {
		return nil
	}
	var out []ConfEntry
	section := ""
	for _, raw := range strings.Split(string(data), "\n") {
		line := confTrim(raw)
		switch {
		case line == "" || strings.HasPrefix(line, "#"):
			continue
		case strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]"):
			section = confSectionOf(line)
			continue
		}
		eq := strings.IndexByte(line, '=')
		if eq < 0 {
			continue
		}
		key := confTrim(line[:eq])
		value := line[eq+1:]
		if i := strings.IndexByte(value, '#'); i >= 0 {
			value = value[:i]
		}
		out = append(out, ConfEntry{Section: section, Key: key, Value: confTrim(value)})
	}
	return out
}

// Get returns the value of key in section, or an empty string when absent.
func (c Conf) Get(section, key string) string {
	for _, e := range c.Entries() {
		if e.Section == section && e.Key == key {
			return e.Value
		}
	}
	return ""
}

// Sections returns the names of the sections whose header is "[prefix <name>]",
// in file order.
func (c Conf) Sections(prefix string) []string {
	data, err := os.ReadFile(c.Path)
	if err != nil {
		return nil
	}
	want := prefix + " "
	var out []string
	for _, raw := range strings.Split(string(data), "\n") {
		t := confTrim(raw)
		if !strings.HasPrefix(t, "[") || !strings.HasSuffix(t, "]") {
			continue
		}
		name := confSectionOf(t)
		if !strings.HasPrefix(name, want) {
			continue
		}
		name = confTrim(strings.TrimPrefix(name, prefix))
		if name != "" {
			out = append(out, name)
		}
	}
	return out
}

// confWithout returns the file without the given section (its header and its
// keys), keeping every other line in order.
func confWithout(path, section string) []string {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	var out []string
	skip := false
	for _, raw := range strings.Split(string(data), "\n") {
		t := confTrim(raw)
		if strings.HasPrefix(t, "[") && strings.HasSuffix(t, "]") {
			if confSectionOf(t) == section {
				skip = true
				continue
			}
			skip = false
		}
		if skip {
			continue
		}
		out = append(out, raw)
	}
	// strings.Split on a file ending with \n gives a trailing empty line; drop it
	// so the caller can add its own spacing consistently.
	for len(out) > 0 && out[len(out)-1] == "" {
		out = out[:len(out)-1]
	}
	return out
}

// confSqueeze removes runs of blank lines, keeping at most one blank line in a
// row, as `cat -s` does in the shell implementation.
func confSqueeze(lines []string) []string {
	var out []string
	blank := false
	for _, l := range lines {
		if l == "" {
			if blank {
				continue
			}
			blank = true
			out = append(out, l)
			continue
		}
		blank = false
		out = append(out, l)
	}
	return out
}

// Set replaces section with the given key=value pairs, or adds it at the end
// when absent. A missing file is created with the standard header.
func (c Conf) Set(section string, pairs ...string) error {
	var lines []string
	if _, err := os.Stat(c.Path); err == nil {
		lines = confWithout(c.Path, section)
	} else {
		for _, l := range strings.Split(strings.TrimSuffix(confHeader, "\n"), "\n") {
			lines = append(lines, l)
		}
	}
	lines = append(lines, "", "["+section+"]")
	for _, kv := range pairs {
		eq := strings.IndexByte(kv, '=')
		if eq < 0 {
			lines = append(lines, "    "+kv+" = ")
			continue
		}
		lines = append(lines, "    "+kv[:eq]+" = "+kv[eq+1:])
	}
	lines = confSqueeze(lines)
	out := strings.Join(lines, "\n")
	if !strings.HasSuffix(out, "\n") {
		out += "\n"
	}
	if err := os.MkdirAll(filepath.Dir(c.Path), 0o755); err != nil {
		return err
	}
	return os.WriteFile(c.Path, []byte(out), 0o644)
}

// Remove drops section from the file; a missing file is not an error.
func (c Conf) Remove(section string) error {
	if _, err := os.Stat(c.Path); err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	lines := confSqueeze(confWithout(c.Path, section))
	out := strings.Join(lines, "\n")
	if out != "" && !strings.HasSuffix(out, "\n") {
		out += "\n"
	}
	return os.WriteFile(c.Path, []byte(out), 0o644)
}
