package agent

import "strings"

// yamlLine is one significant line of a small YAML document.
type yamlLine struct {
	indent int
	text   string
}

// YAMLPodValid reports whether data is a YAML Pod with a metadata.name and at
// least one spec.containers entry. It parses the small YAML subset emitted by
// BuildManifest and used by the removed agent-pod bats fixtures, so no external
// YAML dependency is needed. Syntax errors and non-Pod documents are refused.
func YAMLPodValid(data []byte) bool {
	var lines []yamlLine
	for _, raw := range strings.Split(string(data), "\n") {
		trimmed := strings.TrimLeft(raw, " \t")
		text := strings.TrimRight(trimmed, " \r\t")
		if text == "" || strings.HasPrefix(text, "#") {
			continue
		}
		if strings.Contains(raw[:len(raw)-len(trimmed)], "\t") || !yamlBalanced(text) {
			return false
		}
		lines = append(lines, yamlLine{indent: len(raw) - len(trimmed), text: text})
	}
	kind := ""
	hasName := false
	hasContainers := false
	for i, l := range lines {
		if l.indent != 0 {
			continue
		}
		key, value, ok := yamlKeyValue(l.text)
		if !ok {
			continue
		}
		switch key {
		case "kind":
			kind = yamlUnquote(value)
		case "metadata":
			hasName = yamlBlockHasName(lines, i)
		case "spec":
			hasContainers = yamlBlockHasContainers(lines, i)
		}
	}
	return kind == "Pod" && hasName && hasContainers
}

// yamlBalanced checks that quotes and flow brackets of a YAML line are closed.
func yamlBalanced(s string) bool {
	var quote byte
	depth := 0
	for i := 0; i < len(s); i++ {
		c := s[i]
		if quote != 0 {
			if c == quote {
				quote = 0
			}
			continue
		}
		switch c {
		case '\'', '"':
			quote = c
		case '[', '{':
			depth++
		case ']', '}':
			depth--
			if depth < 0 {
				return false
			}
		case '#':
			return true
		}
	}
	return quote == 0 && depth == 0
}

// yamlKeyValue splits a mapping line into its key and value.
func yamlKeyValue(s string) (string, string, bool) {
	i := strings.IndexByte(s, ':')
	if i <= 0 {
		return "", "", false
	}
	return strings.TrimSpace(s[:i]), strings.TrimSpace(s[i+1:]), true
}

// yamlUnquote removes the surrounding quotes of a YAML scalar.
func yamlUnquote(s string) string {
	if len(s) >= 2 && (s[0] == '"' || s[0] == '\'') && s[len(s)-1] == s[0] {
		return s[1 : len(s)-1]
	}
	return s
}

// yamlBlockHasName reports whether a metadata block holds a non-empty name.
func yamlBlockHasName(lines []yamlLine, i int) bool {
	for j := i + 1; j < len(lines) && lines[j].indent > lines[i].indent; j++ {
		key, value, ok := yamlKeyValue(lines[j].text)
		if ok && key == "name" && yamlUnquote(value) != "" {
			return true
		}
	}
	return false
}

// yamlBlockHasContainers reports whether a spec block has a non-empty container
// list, either in flow style or as a "- " sequence.
func yamlBlockHasContainers(lines []yamlLine, i int) bool {
	for j := i + 1; j < len(lines) && lines[j].indent > lines[i].indent; j++ {
		key, value, ok := yamlKeyValue(lines[j].text)
		if !ok || key != "containers" {
			continue
		}
		value = yamlUnquote(strings.TrimSpace(value))
		if strings.HasPrefix(value, "[") && strings.HasSuffix(value, "]") {
			return strings.TrimSpace(value[1:len(value)-1]) != ""
		}
		for k := j + 1; k < len(lines) && lines[k].indent >= lines[j].indent; k++ {
			if lines[k].indent > lines[j].indent {
				break
			}
			if strings.HasPrefix(lines[k].text, "- ") {
				return true
			}
		}
	}
	return false
}
