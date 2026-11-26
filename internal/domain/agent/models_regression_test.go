package agent

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// agent-models regression (#643): fallback list + opencode.jsonc defaults.
func TestAgentModelsRegression(t *testing.T) {
	repoDC := repoDevcontainer(t)
	config, err := os.ReadFile(filepath.Join(repoDC, "opencode.jsonc"))
	if err != nil {
		t.Fatal(err)
	}
	// strip // comments for parsing
	cfg := string(config)
	configNoComments := stripJSONCComments(cfg)
	// retired models absent from opencode.jsonc and fallback
	for _, model := range []string{"glm-5.3-flash-free", "nemotron-3-ultra-free"} {
		if strings.Contains(cfg, model) || contains(FreeModelsDefault, model) {
			t.Fatal("retired model referenced", model)
		}
	}
	// every opencode model in config is in fallback or top-level default
	modelRe := regexp.MustCompile(`"opencode/[A-Za-z0-9._-]+"`)
	var available []string
	for _, m := range FreeModelsDefault {
		available = append(available, m)
	}
	var defaults []string
	// extract defaults
	for _, line := range strings.Split(configNoComments, "\n") {
		if regexp.MustCompile(`^\s*"(model|small_model)":\s*"opencode/`).MatchString(line) {
			parts := strings.Split(line, `"`)
			if len(parts) >= 4 {
				defaults = append(defaults, strings.TrimPrefix(parts[3], "opencode/"))
			}
		}
	}
	defaults = sortedStrings(defaults)
	available = sortedStrings(available)
	// collect config models
	var configModels []string
	for _, m := range modelRe.FindAllString(configNoComments, -1) {
		configModels = append(configModels, strings.TrimSuffix(strings.TrimPrefix(m, `"opencode/`), `"`))
	}
	configModels = sortedStrings(uniq(configModels))
	if len(configModels) == 0 || len(available) == 0 {
		t.Fatal("no models")
	}
	for _, model := range configModels {
		if in(defaults, model) {
			continue
		}
		if !in(available, model) {
			t.Fatal("model missing from fallback list", model)
		}
	}
}

func stripJSONCComments(s string) string {
	var out strings.Builder
	for _, line := range strings.Split(s, "\n") {
		trimmed := strings.TrimLeft(line, " \t")
		if strings.HasPrefix(trimmed, "//") {
			continue
		}
		// strip trailing // comment not in string
		out.WriteString(line)
		out.WriteByte('\n')
	}
	return out.String()
}

func uniq(in []string) []string {
	seen := map[string]bool{}
	var out []string
	for _, s := range in {
		if !seen[s] {
			seen[s] = true
			out = append(out, s)
		}
	}
	return out
}

func in(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}
