package ai

import (
	"context"
	"encoding/json"
	"os"
	"sort"
	"strings"
)

// measurement is the recorded result of one model.
type measurement struct {
	Reussite float64 `json:"reussite"`
	TokS     float64 `json:"tok_s"`
}

// measuredChoice returns the best measured model among the detected names, or
// an empty string when the file is absent, invalid or has no match.
func measuredChoice(o Options, names []string) string {
	data, err := os.ReadFile(o.measuresFile())
	if err != nil || len(data) == 0 {
		return ""
	}
	var entries map[string]measurement
	if json.Unmarshal(data, &entries) != nil {
		return ""
	}
	detected := map[string]bool{}
	for _, name := range names {
		detected[name] = true
	}
	type scored struct {
		name string
		m    measurement
	}
	var candidates []scored
	for name, m := range entries {
		if detected[name] {
			candidates = append(candidates, scored{name, m})
		}
	}
	if len(candidates) == 0 {
		return ""
	}
	sort.Slice(candidates, func(i, j int) bool {
		a, b := candidates[i].m, candidates[j].m
		if a.Reussite != b.Reussite {
			return a.Reussite > b.Reussite
		}
		return a.TokS > b.TokS
	})
	return candidates[0].name
}

// ruleChoice picks a name containing coder first, then the smallest size and
// finally the name order, as the installed deterministic rule did.
func ruleChoice(ctx context.Context, o Options) string {
	best := ""
	bestCoder, bestSize, bestName := 1, int64(0), ""
	for _, m := range Infos(ctx, o) {
		coder := 1
		if strings.Contains(strings.ToLower(m.name), "coder") {
			coder = 0
		}
		if best == "" || coder < bestCoder || (coder == bestCoder && m.size < bestSize) ||
			(coder == bestCoder && m.size == bestSize && m.name < bestName) {
			best, bestCoder, bestSize, bestName = m.name, coder, m.size, m.name
		}
	}
	return best
}

// First returns the model to use: the forced variable, else the best measured
// one, else the deterministic rule.
func First(ctx context.Context, o Options, names []string) string {
	if forced := o.hostModel(); forced != "" {
		return forced
	}
	if measured := measuredChoice(o, names); measured != "" {
		return measured
	}
	return ruleChoice(ctx, o)
}

// measurementFor returns the recorded success and speed of one model.
func measurementFor(o Options, name string) (float64, float64, bool) {
	data, err := os.ReadFile(o.measuresFile())
	if err != nil || len(data) == 0 {
		return 0, 0, false
	}
	var entries map[string]measurement
	if json.Unmarshal(data, &entries) != nil {
		return 0, 0, false
	}
	m, ok := entries[name]
	return m.Reussite, m.TokS, ok
}
