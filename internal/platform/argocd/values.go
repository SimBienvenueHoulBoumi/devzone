package argocd

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

// workspaceValueKeys are the six settings offered by the generated values
// file. Any other key in a user file is reported, but never rejected.
var workspaceValueKeys = map[string]bool{
	"livenessProbe.thresholdPercent":    true,
	"livenessProbe.periodSeconds":       true,
	"livenessProbe.failureThreshold":    true,
	"livenessProbe.initialDelaySeconds": true,
	"resources.limits.memory":           true,
	"resources.requests.memory":         true,
}

// memoryQuantity accepts the readable Kubernetes memory quantities used by
// the chart defaults, including a bare number of bytes and a decimal value.
var memoryQuantity = regexp.MustCompile(`^[0-9]+(\.[0-9]+)?(Ei|Pi|Ti|Gi|Mi|Ki|E|P|T|G|M|K|k)?$`)

// yamlLevel records a mapping key and its indentation, so nested keys can be
// reported with their full dotted path.
type yamlLevel struct {
	indent int
	name   string
}

// ValidateWorkspaceValues returns plain-language problems found in the
// workspace values file. It is a pure reader: unknown keys, out-of-range probe
// thresholds and unreadable memory are reported without stopping deployment.
func ValidateWorkspaceValues(data []byte) []string {
	var problems []string
	var levels []yamlLevel
	for number, raw := range strings.Split(string(data), "\n") {
		line := strings.TrimSpace(stripYAMLComment(raw))
		if line == "" || strings.HasPrefix(line, "-") {
			continue
		}
		indent := len(raw) - len(strings.TrimLeft(raw, " \t"))
		key, value, hasValue := strings.Cut(line, ":")
		if !hasValue || strings.TrimSpace(key) == "" {
			continue
		}
		for len(levels) > 0 && levels[len(levels)-1].indent >= indent {
			levels = levels[:len(levels)-1]
		}
		name := strings.TrimSpace(key)
		if len(levels) == 0 && strings.Contains(name, ".") {
			problems = append(problems, fmt.Sprintf("line %d: %s is a flat key that Helm ignores: write it nested", number+1, name))
			continue
		}
		if len(levels) > 0 {
			name = levels[len(levels)-1].name + "." + name
		}
		if hasValue && strings.TrimSpace(value) == "" {
			levels = append(levels, yamlLevel{indent: indent, name: name})
			continue
		}
		problems = append(problems, checkWorkspaceValue(number+1, name, value)...)
	}
	return problems
}

// checkWorkspaceValue reports the problems of one leaf of the values file.
func checkWorkspaceValue(line int, key, value string) []string {
	value = cleanYAMLValue(value)
	if !workspaceValueKeys[key] {
		return []string{fmt.Sprintf("line %d: unknown key %s", line, key)}
	}
	if key == "resources.limits.memory" || key == "resources.requests.memory" {
		if !memoryQuantity.MatchString(value) {
			return []string{fmt.Sprintf("line %d: %s is not a readable memory quantity: %q", line, key, value)}
		}
		return nil
	}
	n, err := strconv.Atoi(value)
	if err != nil {
		return []string{fmt.Sprintf("line %d: %s must be a whole number: %q", line, key, value)}
	}
	if key == "livenessProbe.thresholdPercent" && (n < 50 || n > 95) {
		return []string{fmt.Sprintf("line %d: %s must be between 50 and 95 (got %d)", line, key, n)}
	}
	return nil
}

// stripYAMLComment removes a trailing comment without touching a hash inside
// a quoted value, so a user note cannot hide a bad key or quantity.
func stripYAMLComment(line string) string {
	quote := byte(0)
	for i := 0; i < len(line); i++ {
		c := line[i]
		if quote != 0 {
			if c == quote {
				quote = 0
			}
			continue
		}
		if c == '\'' || c == '"' {
			quote = c
			continue
		}
		if c == '#' && (i == 0 || line[i-1] == ' ' || line[i-1] == '\t') {
			return line[:i]
		}
	}
	return line
}

// cleanYAMLValue removes the quotes around a scalar value, when present.
func cleanYAMLValue(value string) string {
	value = strings.TrimSpace(value)
	if len(value) < 2 {
		return value
	}
	if (value[0] == '"' && value[len(value)-1] == '"') || (value[0] == '\'' && value[len(value)-1] == '\'') {
		return value[1 : len(value)-1]
	}
	return value
}
