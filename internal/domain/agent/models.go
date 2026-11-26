package agent

import (
	"context"
	"strings"
)

// FreeModelsDefault is the hardcoded free-model fallback list (#643), kept in
// sync with opencode.jsonc; agent.sh FREE_MODELS. No duplicate name.
var FreeModelsDefault = []string{
	"big-pickle",
	"deepseek-v4.1-flash-free",
	"hy4-flash-free",
	"nemotron-3.5-super-vl-free",
	"nemotron-3.5-lightning-free",
	"mimo-v2.6-flash-free",
	"beam-free",
	"flint-40b-free",
	"longcat-2.5-free",
}

// ListModels returns free models of the installed opencode version, "opencode/"
// prefix removed: `opencode models opencode`, filter (-free$|^big-pickle$),
// dedupe keep order; fallback list when empty. Shell list_models.
func ListModels(ctx context.Context, r Runner, fallback []string) []string {
	var out []string
	if r != nil {
		res, err := r.Run(ctx, "opencode", []string{"models", "opencode"}, Opts{})
		if err == nil && res.Code == 0 {
			seen := map[string]bool{}
			for _, line := range strings.Split(string(res.Stdout), "\n") {
				line = strings.TrimRight(line, "\r")
				name := strings.TrimPrefix(line, "opencode/")
				if name == "" {
					continue
				}
				if !(strings.HasSuffix(name, "-free") || name == "big-pickle") {
					continue
				}
				if seen[name] {
					continue
				}
				seen[name] = true
				out = append(out, name)
			}
		}
	}
	if len(out) == 0 {
		return append([]string{}, fallback...)
	}
	return out
}

// OrderAdd adds model unless already in order.
func OrderAdd(order []string, model string) []string {
	for _, m := range order {
		if m == model {
			return order
		}
	}
	return append(order, model)
}

// ModelOrder builds attempt order from rank start (#420): requested models
// first in order, then usual rotation (online, then local); each once.
func ModelOrder(start int, requested []string, total int, atRank func(rank int) string) []string {
	var order []string
	for _, m := range requested {
		order = OrderAdd(order, m)
	}
	for i := 0; i < total; i++ {
		order = OrderAdd(order, atRank(i))
	}
	return order
}
