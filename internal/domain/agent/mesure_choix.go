package agent

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
)

// mesureChoix returns best measured model among liste (highest reussite, then
// tok_s); empty when file absent/invalid or no match. Reads DEVZONE_AI_MEASURES
// else ~/.config/devzone/ai-measures.json.
func mesureChoix(liste []string, home string) string {
	measures := os.Getenv("DEVZONE_AI_MEASURES")
	if measures == "" {
		measures = filepath.Join(home, ".config", "devzone", "ai-measures.json")
	}
	data, err := os.ReadFile(measures)
	if err != nil || len(data) == 0 {
		return ""
	}
	var entries map[string]struct {
		Reussite float64 `json:"reussite"`
		TokS     float64 `json:"tok_s"`
	}
	if json.Unmarshal(data, &entries) != nil {
		return ""
	}
	set := map[string]bool{}
	for _, n := range liste {
		set[n] = true
	}
	type scored struct {
		key string
		reu float64
		tok float64
	}
	var cand []scored
	for k, v := range entries {
		if !set[k] {
			continue
		}
		cand = append(cand, scored{k, v.Reussite, v.TokS})
	}
	if len(cand) == 0 {
		return ""
	}
	sort.Slice(cand, func(i, j int) bool {
		if cand[i].reu != cand[j].reu {
			return cand[i].reu > cand[j].reu
		}
		return cand[i].tok > cand[j].tok
	})
	return cand[0].key
}
