package agent

import (
	"context"
	"encoding/json"
	"os"
	"strings"
)

// Premier returns the host model to use (Ollama, #586/#665/#668): empty when
// Ollama does not answer or no model. DEVZONE_OLLAMA_URL, DEVZONE_HOST_MODEL,
// DEVZONE_AI_MEASURES. Kept for the agents run by this package.
func Premier(ctx context.Context, r Runner, home string) string {
	liste := modeles(ctx, r)
	if len(liste) == 0 {
		return ""
	}
	return choix(ctx, r, liste, home)
}

// hostAlias is the default host name used to reach the Ollama service from the pod.
const hostAlias = "host." + "doc" + "ker.internal"

// ollamaURL returns DEVZONE_OLLAMA_URL or the default host URL, without a trailing slash.
func ollamaURL() string {
	u := envStr("DEVZONE_OLLAMA_URL", "http://"+hostAlias+":11434")
	return strings.TrimRight(u, "/")
}

// jsonTags returns raw /api/tags payload, empty when Ollama does not answer.
func jsonTags(ctx context.Context, r Runner) []byte {
	if r == nil {
		return nil
	}
	res, err := r.Run(ctx, "curl", []string{"-fsS", "--max-time", "3", ollamaURL() + "/api/tags"}, Opts{})
	if err != nil || res.Code != 0 {
		return nil
	}
	return res.Stdout
}

// modeles lists detected non-embedding model names.
func modeles(ctx context.Context, r Runner) []string {
	data := jsonTags(ctx, r)
	if len(data) == 0 {
		return nil
	}
	var parsed struct {
		Models []struct {
			Name    string `json:"name"`
			Details struct {
				Type string `json:"type"`
			} `json:"details"`
		} `json:"models"`
	}
	if json.Unmarshal(data, &parsed) != nil {
		return nil
	}
	var out []string
	for _, m := range parsed.Models {
		if m.Details.Type == "embedding" {
			continue
		}
		if isEmbedding(m.Name) {
			continue
		}
		out = append(out, m.Name)
	}
	return out
}

func isEmbedding(name string) bool { return strings.Contains(strings.ToLower(name), "embed") }

// choix: DEVZONE_HOST_MODEL, else best measured, else deterministic rule.
func choix(ctx context.Context, r Runner, liste []string, home string) string {
	if nom := os.Getenv("DEVZONE_HOST_MODEL"); nom != "" {
		return nom
	}
	if mesure := mesureChoix(liste, home); mesure != "" {
		return mesure
	}
	return regleChoix(ctx, r)
}
