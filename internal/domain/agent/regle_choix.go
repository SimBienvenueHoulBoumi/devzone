package agent

import (
	"context"
	"strings"
)

// regleChoix deterministic fallback: name containing "coder" first, then
// smallest size, then name order (LC_ALL=C). Reads `tailles`. Shell regle_choix.
func regleChoix(ctx context.Context, r Runner) string {
	best := ""
	bc := 1
	var bs int64
	bn := ""
	for _, t := range tailles(ctx, r) {
		low := strings.ToLower(t.name)
		coder := 1
		if strings.Contains(low, "coder") {
			coder = 0
		}
		size := t.size
		if best == "" || coder < bc || (coder == bc && size < bs) || (coder == bc && size == bs && t.name < bn) {
			best = t.name
			bc = coder
			bs = size
			bn = t.name
		}
	}
	return best
}
