package agent

import (
	"strings"
)

// LocalModel state (#586): host model via Ollama `premier`.
type LocalModel struct {
	LocalModel        string // internal slash-free name, empty when none
	LocalHostReal     string // real host model name chosen
	LocalHostInternal string // internal name chosen
}

// InternalName sanitizes a model name: every char outside [A-Za-z0-9._-] -> '_'.
func InternalName(s string) string {
	var b strings.Builder
	for _, r := range s {
		if (r >= 'A' && r <= 'Z') || (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') || r == '.' || r == '_' || r == '-' {
			b.WriteRune(r)
		} else {
			b.WriteByte('_')
		}
	}
	return b.String()
}

// ModelRef returns model reference given to opencode -m.
func (l LocalModel) ModelRef(model string) string {
	if l.LocalHostInternal != "" && model == l.LocalHostInternal {
		return "devzone-host/" + l.LocalHostReal
	}
	return "opencode/" + model
}

// ModelAtRank returns model of rank r in attempt starting at start: online in
// rotation, then local host model. Shell model_at_rank.
func ModelAtRank(rank, start int, freeModels []string, local string) string {
	if rank < len(freeModels) {
		if len(freeModels) == 0 {
			return local
		}
		return freeModels[(start+rank)%len(freeModels)]
	}
	return local
}

// ModelsTotal returns online count + local host model if ready. Shell models_total.
func ModelsTotal(freeModels []string, local string) int {
	total := len(freeModels)
	if local != "" {
		total++
	}
	return total
}
