package agent

import (
	"context"
	"encoding/json"
)

// taille is a detected model name + size bytes.
type taille struct {
	name string
	size int64
}

// tailles returns detected non-embedding models as name+size. Shell `tailles`.
func tailles(ctx context.Context, r Runner) []taille {
	data := jsonTags(ctx, r)
	if len(data) == 0 {
		return nil
	}
	var parsed struct {
		Models []struct {
			Name    string `json:"name"`
			Size    int64  `json:"size"`
			Details struct {
				Type string `json:"type"`
			} `json:"details"`
		} `json:"models"`
	}
	if json.Unmarshal(data, &parsed) != nil {
		return nil
	}
	var out []taille
	for _, m := range parsed.Models {
		if m.Details.Type == "embedding" || isEmbedding(m.Name) {
			continue
		}
		out = append(out, taille{name: m.Name, size: m.Size})
	}
	return out
}
